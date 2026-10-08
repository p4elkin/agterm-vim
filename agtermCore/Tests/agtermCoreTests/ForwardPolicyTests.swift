import Foundation
import Testing
@testable import agtermCore

struct ForwardPolicyTests {
    @Test(arguments: [false, true])
    func rebasedIsRefusedBeforeTheProgramJobRoute(_ holdsJob: Bool) {
        #expect(ForwardPolicy.kind(of: .sessionOverlayOpen) == .routed)
        let request = ControlRequest(cmd: .sessionOverlayOpen, args: ControlArgs(rebased: true))
        #expect(ForwardPolicy.route(request, holdsJob: holdsJob) == .refused("Rebased overlays open on a Mac only"))
    }

    static let served: Set<String> = [
        "tree", "events.read", "version", "window.list", "zmx.new", "zmx.tree", "zmx.present", "zmx.list",
        "notify", "session.status", "session.context", "session.seen", "session.new", "session.mark",
        "session.close", "session.rename", "zmx.kill", "session.split", "session.split.close", "session.swap",
        "session.text", "session.type", "session.hud.open", "session.hud.update", "session.hud.close",
        "ask.open", "ask.result", "ask.cancel", "session.overlay.job.run",
    ]
    static let forwarded: Set<String> = [
        "session.overlay.reload", "session.overlay.navigate", "session.overlay.submit", "session.overlay.copy",
        "session.overlay.text", "pick.open", "pick.result", "pick.cancel",
        "session.flag", "session.select", "session.reveal", "session.focus", "session.background",
        "session.copy", "session.paste", "session.selectall", "session.search",
        "session.bookmark.add", "session.bookmark.list", "session.bookmark.go", "session.bookmark.remove",
    ]
    static let routed: Set<String> = [
        "session.overlay.open", "session.overlay.close", "session.overlay.resize", "session.overlay.result",
        "zmx.attach",
    ]

    @Test func everyCommandHasTheExpectedKind() throws {
        let declared = try Self.declaredCommands()
        #expect(declared.count > 100)
        for name in declared {
            let command = try #require(Command(rawValue: name))
            let kind = ForwardPolicy.kind(of: command)
            if Self.served.contains(name) {
                #expect(kind == .served, "\(name)")
            } else if Self.forwarded.contains(name) {
                #expect(kind == .forwarded, "\(name)")
            } else if Self.routed.contains(name) {
                #expect(kind == .routed, "\(name)")
            } else {
                guard case .refused = kind else {
                    Issue.record("\(name) should be refused, is \(kind)")
                    continue
                }
            }
        }
        #expect(Self.served.union(Self.forwarded).union(Self.routed).isSubset(of: Set(declared)))
    }

    @Test(arguments: [
        ("session.scratch", "no terminal surface"), ("surface.zoom", "no terminal surface"),
        ("surface.cursor", "no terminal surface"), ("session.lead", "no terminal surface"),
        ("session.duplicate", "no windows or UI"), ("session.move", "no windows or UI"),
        ("session.park", "no windows or UI"), ("session.resize", "no windows or UI"), ("session.go", "no windows or UI"),
        ("window.new", "no windows or UI"), ("theme.set", "no windows or UI"), ("mode", "no windows or UI"),
        ("hooks.reload", "a Mac feature"), ("session.restore", "a Mac feature"), ("session.pairing", "a Mac feature"),
        ("zmx.prune", "a Mac feature"), ("zmx.reset", "a Mac feature"),
        ("browser.clear", "a Mac feature"), ("zmx.screen", "a Mac feature"), ("keymap.run", "no windows or UI"),
    ])
    func refusalsCarryTheirReason(_ name: String, _ reason: String) throws {
        let command = try #require(Command(rawValue: name))

        #expect(ForwardPolicy.kind(of: command) == .refused(reason))
        #expect(ForwardPolicy.route(ControlRequest(cmd: command), holdsJob: false) == .refused(reason))
    }

    @Test func aServedCommandIsServedAndAForwardedOneForwarded() {
        #expect(ForwardPolicy.route(ControlRequest(cmd: .notify), holdsJob: false) == .served)
        #expect(ForwardPolicy.route(ControlRequest(cmd: .sessionFlag), holdsJob: true) == .forwarded)
        #expect(ForwardPolicy.route(ControlRequest(cmd: .pickResult), holdsJob: false) == .forwarded)
    }

    @Test func attachIsForwardedOnlyInItsBesideForm() {
        var args = ControlArgs(host: "p4linux")
        #expect(ForwardPolicy.route(ControlRequest(cmd: .zmxAttach, target: "s1", args: args), holdsJob: false)
            == .refused("a Mac feature"))
        args.attach = "s2"

        #expect(ForwardPolicy.route(ControlRequest(cmd: .zmxAttach, target: "s1", args: args), holdsJob: false) == .forwarded)
    }

    @Test func typeIsServedButItsSelectIsRefused() {
        var args = ControlArgs()
        args.text = "x"
        #expect(ForwardPolicy.route(ControlRequest(cmd: .sessionType, args: args), holdsJob: false) == .served)
        args.select = true

        #expect(ForwardPolicy.route(ControlRequest(cmd: .sessionType, args: args), holdsJob: false) == .refused("it has no selection"))
    }

    @Test func overlayOpenRoutesByContent() {
        func open(_ edit: (inout ControlArgs) -> Void) -> ForwardPolicy.Route {
            var args = ControlArgs()
            args.command = "revdiff"
            edit(&args)
            return ForwardPolicy.route(ControlRequest(cmd: .sessionOverlayOpen, args: args), holdsJob: false)
        }

        #expect(open { _ in } == .job)
        #expect(open { $0.command = nil; $0.url = "http://example.com" } == .forwarded)
        #expect(open { $0.command = nil; $0.html = "/tmp/page.html" } == .refused("an --html page is a file on the origin; use --url"))
        #expect(open { $0.url = "http://example.com"; $0.html = "/tmp/page.html" } == .refused("an --html page is a file on the origin; use --url"))
    }

    @Test func resultIsServedUnlessItPollsAPage() {
        let program = ControlRequest(cmd: .sessionOverlayResult)
        var args = ControlArgs()
        args.page = UUID().uuidString
        let page = ControlRequest(cmd: .sessionOverlayResult, args: args)

        #expect(ForwardPolicy.route(program, holdsJob: false) == .served)
        #expect(ForwardPolicy.route(program, holdsJob: true) == .served)
        #expect(ForwardPolicy.route(page, holdsJob: true) == .forwarded)
    }

    @Test(arguments: [Command.sessionOverlayClose, .sessionOverlayResize])
    func closeAndResizeAreServedOnlyForAJobTheServerHolds(_ command: Command) {
        #expect(ForwardPolicy.route(ControlRequest(cmd: command), holdsJob: true) == .served)
        #expect(ForwardPolicy.route(ControlRequest(cmd: command), holdsJob: false) == .forwarded)
    }

    /// `Command` is not `CaseIterable`, so its cases are read from the declaration: one `case` per line.
    private static func declaredCommands() throws -> [String] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/agtermCore/ControlProtocol.swift")
        let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("public enum Command:") })
        let end = try #require(lines[start...].firstIndex { $0 == "}" })
        return lines[start..<end].compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { return nil }
            let parts = trimmed.dropFirst("case ".count).components(separatedBy: " = ")
            return parts.count == 2 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : parts[0]
        }
    }
}
