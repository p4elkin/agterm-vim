import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
final class HeadlessActionFixture {
    let directory: URL
    let runner: FakeZmxRunner
    let streams = ActionTestStreams()
    let headless: Headless
    let actions: HeadlessActions
    let store: AppStore
    let session: Session

    init(build: String? = nil, runner: FakeZmxRunner = FakeZmxRunner(), shellLookup: @escaping () -> String? = { "/bin/sh" },
         hudClock: @escaping () -> Date = Date.init, overlayClock: @escaping () -> Date = Date.init,
         procRoot: String = "/proc") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let build { try build.write(to: directory.appendingPathComponent("BUILD"), atomically: true, encoding: .utf8) }
        self.runner = runner
        let config = HeadlessConfig.fromEnvironment([
            "AGTERM_HEADLESS_STATE": directory.appendingPathComponent("state").path,
            "AGTERM_HEADLESS_ZMX": directory.appendingPathComponent("unused-zmx").path,
            "LANG": "en_US.UTF-8",
        ])
        let streams = streams
        headless = Headless(config: config, runner: runner, shellLookup: shellLookup, overlayClock: overlayClock,
                            procRoot: procRoot) { _, _ in streams }
        let window = try #require(headless.library.windows.first)
        store = try #require(headless.library.store(for: window.id))
        session = try #require(store.workspaces.first?.sessions.first)
        actions = HeadlessActions(headless: headless, installDirectory: directory, hudClock: hudClock)
    }

    func cleanUp() {
        for session in store.workspaces.flatMap(\.sessions) {
            if session.hudActive { store.closeHud(session.id) }
            if let ask = session.askPending { session.cancelAsk(id: ask.id) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func dispatch(_ command: Command, target: String? = nil, _ edit: (inout ControlArgs) -> Void = { _ in }) async throws -> ControlResponse {
        let request = HeadlessRequests.request(command, target: target ?? session.id.uuidString, edit)
        return try #require(await ControlDispatcher(actions: actions).dispatch(request))
    }

    func node() async throws -> ControlSessionNode {
        let response = try await dispatch(.tree)
        return try #require(response.result?.tree?.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
    }

    /// Shows a split on the fixture session with a daemon-backed right pane, as the server's own split does.
    func split() throws -> UUID {
        store.setSplitVisibility(session.id, shown: true)
        let split = try #require(session.splitPaneIdentity)
        session.splitSurface = DaemonSurface(paneIdentity: split)
        return split
    }

    func sessionIDs() async throws -> [String] {
        try await dispatch(.tree).result?.tree?.workspaces.flatMap(\.sessions).map(\.id) ?? []
    }

    var listing: String { "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=42\tclients=0\n" }
}

@MainActor
final class ActionTestStreams: HeadlessStreams {
    var adopted: [(UUID, Int32)] = []
    var response: ControlResponse?
    func adopt(session: UUID, fd: Int32) -> ControlResponse? {
        adopted.append((session, fd))
        return response
    }
    var closed: [UUID] = []
    func closeStreams(session: UUID) { closed.append(session) }

    final class Job: HeadlessJobTransport {
        let reply: ControlResponse
        let onLine: @MainActor (Data) -> Void
        let onClose: @MainActor () -> Void
        var lines: [Data] = []
        var isShut = false

        init(reply: ControlResponse, onLine: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor () -> Void) {
            self.reply = reply
            self.onLine = onLine
            self.onClose = onClose
        }

        func send(_ line: Data) -> Bool {
            lines.append(line)
            return true
        }

        func shutdown() { isShut = true }

        var frames: [OverlayJobFrame] { lines.compactMap { try? JSONDecoder().decode(OverlayJobFrame.self, from: $0) } }

        func report(_ frame: OverlayJobFrame) throws { onLine(try frame.line()) }
    }

    /// False makes the next job adoption fail as a reply that could not be written.
    var acceptsJobs = true
    var jobs: [Job] = []
    func adoptJob(fd: Int32, reply: ControlResponse, onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor () -> Void) -> (any HeadlessJobTransport)? {
        guard acceptsJobs else { return nil }
        let job = Job(reply: reply, onLine: onLine, onClose: onClose)
        jobs.append(job)
        return job
    }
}
