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
         hudClock: @escaping () -> Date = Date.init) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let build { try build.write(to: directory.appendingPathComponent("BUILD"), atomically: true, encoding: .utf8) }
        self.runner = runner
        let config = HeadlessConfig.fromEnvironment([
            "AGTERM_HEADLESS_STATE": directory.appendingPathComponent("state").path,
            "AGTERM_HEADLESS_ZMX": directory.appendingPathComponent("unused-zmx").path,
        ])
        let streams = streams
        headless = Headless(config: config, runner: runner, shellLookup: shellLookup) { _, _ in streams }
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
}
