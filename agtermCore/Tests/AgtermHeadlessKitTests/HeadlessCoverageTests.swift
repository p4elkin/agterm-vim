import Foundation
import Testing
import agtermCore
import AgtermHeadlessKit

@MainActor
struct HeadlessCoverageTests {
    @Test func requestListCoversEveryCommandOnce() throws {
        let listed = HeadlessRequests.all.map(\.cmd.rawValue)
        let declared = try Self.declaredCommands()

        #expect(Set(listed).count == listed.count)
        #expect(listed.count == declared.count)
        #expect(Set(listed) == Set(declared))
    }

    @Test(arguments: HeadlessRequests.all)
    func commandsAnswerAccordingToTheCatalog(_ request: ControlRequest) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        if request.cmd == .sessionSwap { _ = try fixture.split() }
        if request.cmd == .sessionHudUpdate || request.cmd == .sessionHudClose {
            #expect(fixture.actions.openHud(fixture.session.id.uuidString, window: nil, spec: HudSpec(message: "existing")).ok)
        }
        var prepared = bound(request, to: fixture)
        if request.cmd == .askResult || request.cmd == .askCancel {
            let opened = try await fixture.dispatch(.askOpen) {
                $0.title = "existing"; $0.buttons = [ControlAskButton(id: "ok", label: "OK")]
            }
            let id = try #require(opened.result?.id)
            prepared = ControlRequest(cmd: request.cmd, target: id, args: request.args)
        }
        let response = await fixture.actions.respond(to: prepared)

        switch HeadlessCatalog.support(for: request.cmd) {
        case .served where request.cmd == .sessionOverlayJobRun: #expect(response.error == "job not claimable")
        case .served: #expect(response.ok)
        case .forwarded where request.cmd == .pickResult || request.cmd == .pickCancel:
            #expect(response.error == "unknown pick: \(prepared.target ?? "")")
        case .refused, .forwarded, .routed:
            switch ForwardPolicy.route(prepared, holdsJob: false) {
            case .forwarded: #expect(response == Self.unpresented(request.cmd))
            case .refused(let reason):
                #expect(response.error == "\(request.cmd.rawValue) is not available on a headless origin: \(reason)")
            case .job: #expect(response.error == "session.overlay.open cannot run a program: no Mac is presenting this session")
            case .served: #expect(response.error == OverlayResultError.noResult)
            }
        }
    }

    @Test(arguments: HeadlessRequests.all)
    func everyRequestHasARouteThatAgreesWithTheCatalog(_ request: ControlRequest) {
        let route = ForwardPolicy.route(request, holdsJob: false)

        switch HeadlessCatalog.support(for: request.cmd) {
        case .served: #expect(route == .served)
        case .forwarded: #expect(route == .forwarded)
        case .refused: #expect(route == ForwardPolicy.route(ControlRequest(cmd: request.cmd), holdsJob: false))
        case .routed: #expect(route != .refused("not routed"))
        }
    }

    @Test(arguments: HeadlessRequests.all)
    func dispatcherAnswersEverythingButTheAppearanceSeam(_ request: ControlRequest) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        if request.cmd == .sessionSwap { _ = try fixture.split() }
        let response = await ControlDispatcher(actions: fixture.actions).dispatch(bound(request, to: fixture))

        #expect((response == nil) == (request.cmd == .debugAppearance))
    }

    @Test func searchAndBookmarkGoAreForwardedAsThemselves() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let search = HeadlessRequests.request(.sessionSearch, target: HeadlessRequests.target) { $0.text = TurnMark.needle(for: 1) }
        let go = HeadlessRequests.request(.sessionBookmarkGo, target: HeadlessRequests.target) { $0.turn = 0 }

        #expect(await fixture.actions.respond(to: bound(search, to: fixture)) == Self.unpresented(.sessionSearch))
        #expect(await fixture.actions.respond(to: bound(go, to: fixture)) == Self.unpresented(.sessionBookmarkGo))
    }

    private static func unpresented(_ command: Command) -> ControlResponse {
        ControlResponse(ok: false, error: "\(command.rawValue) cannot be forwarded: no Mac is presenting this session")
    }

    private func bound(_ request: ControlRequest, to fixture: HeadlessActionFixture) -> ControlRequest {
        ControlRequest(cmd: request.cmd,
                       target: request.target == HeadlessRequests.target ? fixture.session.id.uuidString : request.target,
                       args: request.args)
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
