import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
struct HeadlessForegroundTests {
    private final class Proc {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-proc-\(UUID().uuidString)")

        /// A pane's login shell `shell` whose terminal's foreground group is `group`, running `argv`.
        func pane(shell: Int32, group: Int32, argv: [String]) throws {
            try write("\(shell)/stat", "\(shell) (bash) S 1 \(shell) \(shell) 34816 \(group) 4194304 0 0\n")
            try write("\(group)/cmdline", argv.map { $0 + "\0" }.joined())
        }

        func write(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func listing(_ entries: (UUID, Int32)...) -> ZmxResult {
        .ok(entries.map { "name=\(ZmxSupport.daemonName(for: $0.0))\tpid=\($0.1)\tclients=1\n" }.joined())
    }

    @Test func theTreeReportsTheProgramInEachPanesForegroundGroup() async throws {
        let proc = Proc()
        defer { proc.cleanUp() }
        let fixture = try HeadlessActionFixture(shellLookup: { "/usr/bin/zsh" }, procRoot: proc.root.path)
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        try proc.pane(shell: 4242, group: 4300, argv: ["claude", "--resume"])
        try proc.pane(shell: 5252, group: 5300, argv: ["revdiff"])
        fixture.runner.enqueue(listing((fixture.session.paneIdentity, 4242), (split, 5252)))

        await DaemonWatcher(headless: fixture.headless).poll()
        let node = try await fixture.node()

        #expect(node.foreground == ["claude", "--resume"])
        #expect(node.splitForeground == ["revdiff"])
    }

    @Test func aPipelineWhoseLeaderExitedReportsTheSurvivor() async throws {
        let proc = Proc()
        defer { proc.cleanUp() }
        let fixture = try HeadlessActionFixture(shellLookup: { "/usr/bin/zsh" }, procRoot: proc.root.path)
        defer { fixture.cleanUp() }
        try proc.write("4242/stat", "4242 (zsh) S 1 4242 4242 34816 4300 4194304 0 0\n")
        try proc.write("4301/stat", "4301 (less) S 4242 4300 4242 34816 4300 4194304 0 0\n")
        try proc.write("4301/cmdline", "less\0f\0")
        try proc.write("4302/stat", "4302 (other) S 4242 4302 4242 34816 4300 4194304 0 0\n")
        try proc.write("4302/cmdline", "other\0")
        fixture.runner.enqueue(listing((fixture.session.paneIdentity, 4242)))

        await DaemonWatcher(headless: fixture.headless).poll()

        #expect(try await fixture.node().foreground == ["less", "f"])
    }

    @Test func aShellAtItsPromptIsAForegroundShellNotAProgram() async throws {
        let proc = Proc()
        defer { proc.cleanUp() }
        let fixture = try HeadlessActionFixture(shellLookup: { "/usr/bin/zsh" }, procRoot: proc.root.path)
        defer { fixture.cleanUp() }
        try proc.pane(shell: 4242, group: 4242, argv: ["-bash"])
        fixture.runner.enqueue(listing((fixture.session.paneIdentity, 4242)))

        await DaemonWatcher(headless: fixture.headless).poll()
        let node = try await fixture.node()

        #expect(node.foreground == nil)
        #expect(node.foregroundShell == "bash")
    }

    @Test func aPaneTheWatcherHasNotListedOrAGoneProcessReportsNothing() async throws {
        let proc = Proc()
        defer { proc.cleanUp() }
        let fixture = try HeadlessActionFixture(procRoot: proc.root.path)
        defer { fixture.cleanUp() }

        #expect(try await fixture.node().foreground == nil)

        fixture.runner.enqueue(listing((fixture.session.paneIdentity, 4242)))
        await DaemonWatcher(headless: fixture.headless).poll()

        let node = try await fixture.node()
        #expect(node.foreground == nil)
        #expect(node.foregroundShell == nil)
    }
}
