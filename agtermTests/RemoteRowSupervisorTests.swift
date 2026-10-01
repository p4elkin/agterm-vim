import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteRowSupervisorTests: XCTestCase {
    private var directory: URL!
    private var library: WindowLibrary!
    private var store: AppStore!
    private let originLeft = UUID()
    private let originRight = UUID()
    private var answers: [ControlResponse] = []
    private var trees: [String] = []
    private var sleeps: [TimeInterval] = []
    private var reattached: [RemoteRowSupervisor.Pane] = []
    private var onSleep: (() -> Void)?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-supervisor-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        store = try XCTUnwrap(library.activeStore)
    }

    override func tearDown() async throws {
        store = nil
        library = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func supervisor() -> RemoteRowSupervisor {
        RemoteRowSupervisor(library: library, tree: { [unowned self] host in
            trees.append(host)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }, sleep: { [unowned self] seconds in
            sleeps.append(seconds)
            onSleep?()
        }, reattach: { [unowned self] pane in reattached.append(pane) })
    }

    private func row(split: Bool = false) throws -> Session {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp", command: "ssh p4linux",
                                                     wait: true, remoteHost: "p4linux"))
        var daemons = [session.paneIdentity: ZmxSupport.daemonName(for: originLeft)]
        if split {
            store.toggleSplit(session.id)
            daemons[try XCTUnwrap(session.splitPaneIdentity)] = ZmxSupport.daemonName(for: originRight)
        }
        store.bindRemote(RemoteBinding(remoteSessionID: "R1", daemonsByLocalPane: daemons, presentationVersion: 1,
                                       origin: .init(host: "p4linux", endpoint: endpoint, sessionName: "build")),
                         forSession: session.id)
        return session
    }

    private let endpoint = ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/zmx-p4linux")

    private func tree(listing panes: [UUID]?) throws -> ControlResponse {
        let sessions = panes.map { panes in
            let rows = zip(["left", "right"], panes).map { #"{"pane":"\#($0)","daemon":"\#(ZmxSupport.daemonName(for: $1))"}"# }
            return #"[{"id":"R1","name":"build","windowID":"w","windowName":"main","workspaceID":"ws","workspaceName":"work","#
                + #""cwd":"/","panes":[\#(rows.joined(separator: ","))]}]"#
        } ?? "[]"
        let json = #"{"ok":true,"result":{"remote":{"endpoint":{"executable":"/opt/zmx","socketDirectory":"/tmp/zmx-p4linux"},"#
            + #""sessions":\#(sessions)}}}"#
        return try JSONDecoder().decode(ControlResponse.self, from: Data(json.utf8))
    }

    private func settle(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), description)
    }

    func testADisconnectedRowRetriesThenReattachesWithoutAClaim() async throws {
        let session = try row()
        answers = [ControlResponse(ok: false, error: "ssh: connect to host p4linux: timed out"), try tree(listing: [originLeft])]
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)

        try await settle("reattached") { reattached == [.init(session: session.id, local: session.paneIdentity)] }
        XCTAssertEqual(trees, ["p4linux", "p4linux"])
        XCTAssertEqual(sleeps, [RemoteRowSupervisor.retryInterval])
        XCTAssertEqual(session.remotePresentation?.rowState, .attached)
    }

    func testBothPanesOfOneHostShareOneTreeCall() async throws {
        let session = try row(split: true)
        answers = [try tree(listing: [originLeft, originRight])]
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)
        watcher.paneExited(try XCTUnwrap(session.splitPaneIdentity), inSession: session.id)

        try await settle("both reattached") { reattached.count == 2 }
        XCTAssertEqual(trees.count, 1)
    }

    func testASessionEndedOnTheHostStopsAsking() async throws {
        let session = try row()
        answers = [try tree(listing: nil)]
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)

        try await settle("ended") { session.remotePresentation?.rowState == .endedOnHost }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(trees.count, 1)
        XCTAssertTrue(sleeps.isEmpty)
        XCTAssertTrue(reattached.isEmpty)
    }

    func testClosingTheRowStopsTheRetries() async throws {
        let session = try row()
        answers = [ControlResponse(ok: false, error: "unreachable")]
        onSleep = { [unowned self] in store.closeSession(session.id) }
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)

        try await settle("slept once") { sleeps.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(trees.count, 1)
        XCTAssertTrue(reattached.isEmpty)
    }

    func testASplitClosedOnTheOriginIsNeitherAskedAboutNorReattached() async throws {
        let session = try row(split: true)
        let split = try XCTUnwrap(session.splitPaneIdentity)
        store.applyRemoteLayout(PresentationLayout(panes: [originLeft], primary: originLeft, shown: false), forSession: session.id)
        answers = [try tree(listing: [originLeft])]
        let watcher = supervisor()

        watcher.paneExited(split, inSession: session.id)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(trees.isEmpty)
        XCTAssertTrue(reattached.isEmpty)
    }

    func testAPaneWhoseDaemonTheTreeNoLongerListsIsNotReattached() async throws {
        let session = try row(split: true)
        let split = try XCTUnwrap(session.splitPaneIdentity)
        answers = [try tree(listing: [originLeft])]
        let watcher = supervisor()

        watcher.paneExited(split, inSession: session.id)

        try await settle("classified") { trees.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(reattached.isEmpty, "attaching would create a fresh daemon under the closed pane's name")
    }
}
