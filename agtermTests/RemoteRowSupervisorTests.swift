import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteRowSupervisorTests: XCTestCase {
    private final class NoAttachLines: RemoteAttachLines {
        func paneAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String { "attach \(daemon)" }
        func scratchAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String { "" }
    }

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
    private var onTree: (() -> Void)?
    private var panes: [UUID] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-supervisor-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        store = try XCTUnwrap(library.activeStore)
    }

    override func tearDown() async throws {
        for pane in panes {
            ZmxLeadBook.shared.forget(pane: pane)
            RemoteReconnectBook.shared.cancel(pane: pane)
        }
        panes = []
        store = nil
        library = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func supervisor() -> RemoteRowSupervisor {
        RemoteRowSupervisor(library: library, tree: { [unowned self] host in
            trees.append(host)
            onTree?()
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
        panes += daemons.keys
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

    func testARowThatSleepsWhileItsPaneWaitsIsNotReattached() async throws {
        let session = try row()
        answers = [ControlResponse(ok: false, error: "unreachable"), try tree(listing: [originLeft])]
        onSleep = { [unowned self] in XCTAssertTrue(store.sleepRemoteRow(session.id, reason: .timer)) }
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)

        try await settle("slept once") { sleeps.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(trees.count, 1)
        XCTAssertTrue(reattached.isEmpty, "a wake attaches a sleeping row with fresh lines")
        XCTAssertEqual(session.remotePresentation?.rowState, .attached, "nothing retries an asleep row")
    }

    func testARowThatSleepsWhileAFailingTreeCallIsOutKeepsItsState() async throws {
        let session = try row()
        answers = [ControlResponse(ok: false, error: "unreachable")]
        onTree = { [unowned self] in XCTAssertTrue(store.sleepRemoteRow(session.id, reason: .timer)) }
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)

        try await settle("asked") { trees.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.remotePresentation?.rowState, .attached)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testARowThatSleepsWhileItsTreeCallIsOutIsNotReattached() async throws {
        let session = try row()
        answers = [try tree(listing: [originLeft])]
        onTree = { [unowned self] in XCTAssertTrue(store.sleepRemoteRow(session.id, reason: .timer)) }
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)

        try await settle("asked") { trees.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(reattached.isEmpty)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testASleepForgetsAHeldExit() throws {
        let session = try row()
        store.remotePaneHeld(session.paneIdentity, forSession: session.id)
        XCTAssertTrue(store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))

        XCTAssertTrue(store.sleepRemoteRow(session.id, reason: .timer))

        XCTAssertFalse(store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))
    }

    func testAFailedStreamOnASleepingRowStillReadsEndedOnHost() async throws {
        let session = try row()
        XCTAssertTrue(store.sleepRemoteRow(session.id, reason: .timer))
        answers = [try tree(listing: nil)]
        let watcher = supervisor()

        watcher.streamFailed(inSession: session.id)

        try await settle("ended") { session.remotePresentation?.rowState == .endedOnHost }
        XCTAssertTrue(session.asleep)
    }

    func testASleepClaimsThePaneExitSoTheSupervisorIsNeverTold() throws {
        let session = try row()
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: "/bin/cat")
        view.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        session.surface = view
        view.onExit = {}
        view.onExitHeld = {}

        XCTAssertTrue(store.sleepRemoteRow(session.id, reason: .timer))

        XCTAssertFalse(view.claimProcessExit(), "the exit is claimed before the surface is freed")
        XCTAssertNil(view.onExit)
        XCTAssertNil(view.onExitHeld, "a held exit queued before the sleep reaches no supervisor")
    }

    // the reconnect book attached the pane while the tree call was out
    func testAPaneAttachedAgainBeforeTheAnswerIsNotReattached() async throws {
        let session = try row()
        answers = [try tree(listing: [originLeft])]
        let watcher = supervisor()

        watcher.paneExited(session.paneIdentity, inSession: session.id)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: false), pane: session.paneIdentity, reattaching: true)

        try await settle("classified") { session.remotePresentation?.rowState == .attached }
        try await settle("asked once and done") { trees.count == 1 && sleeps.isEmpty }
        XCTAssertTrue(reattached.isEmpty)
    }

    func testAPaneWaitingToReconnectIsProbedNowAndReattachedOnlyOnceTheBookLetsItGo() async throws {
        let session = try row()
        let pane = session.paneIdentity
        answers = [try tree(listing: [originLeft])]
        let book = RemoteReconnectBook.shared
        book.wait(pane: pane, session: session.id, host: "p4linux", cover: true, now: Date())
        _ = book.due(now: Date())
        _ = book.finished(pane: pane, ok: false, now: Date().addingTimeInterval(3600))
        XCTAssertTrue(book.due(now: Date()).isEmpty, "backing off")
        var probedNow = false
        onSleep = { [unowned self] in
            guard sleeps.count == 1 else { return }
            XCTAssertTrue(reattached.isEmpty, "the book owns the attach of a dropped link")
            probedNow = book.due(now: Date()) == [pane]
            book.cancel(pane: pane)
        }
        let watcher = supervisor()

        watcher.paneExited(pane, inSession: session.id)

        try await settle("reattached as the backstop") { reattached == [.init(session: session.id, local: pane)] }
        XCTAssertTrue(probedNow, "the host answered, so the probe does not wait for its backoff")
        XCTAssertEqual(trees.count, 2)
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
        store.applyRemoteLayout(PresentationLayout(panes: [originLeft], primary: originLeft, shown: false),
                                forSession: session.id, attach: NoAttachLines())
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

    func testAFailedStreamOnARowWhoseSessionEndedReadsEndedOnHost() async throws {
        let session = try row()
        answers = [try tree(listing: nil)]
        let watcher = supervisor()

        watcher.streamFailed(inSession: session.id)

        try await settle("ended") { session.remotePresentation?.rowState == .endedOnHost }
        XCTAssertEqual(session.remotePresentation?.rowNotice(host: "p4linux"), "Ended on p4linux. Close the row to remove it")
        XCTAssertTrue(sleeps.isEmpty)
        XCTAssertTrue(reattached.isEmpty)
    }

    func testAFailedStreamKeepsAttachedWhileTheSessionIsListedOrTheHostIsUnreachable() async throws {
        let session = try row()
        answers = [try tree(listing: [originLeft]), ControlResponse(ok: false, error: "unreachable")]
        let watcher = supervisor()

        watcher.streamFailed(inSession: session.id)
        try await settle("listed") { trees.count == 1 }
        watcher.streamFailed(inSession: session.id)
        try await settle("unreachable") { trees.count == 2 }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(session.remotePresentation?.rowState, .attached, "nothing would clear a disconnected set without a waiting pane")
        XCTAssertTrue(sleeps.isEmpty)
        XCTAssertEqual(trees.count, 2)
    }

    func testAStreamThatReconnectedBeforeTheAnswerKeepsTheRowAttached() async throws {
        let session = try row()
        answers = [try tree(listing: nil)]
        let watcher = supervisor()

        watcher.streamFailed(inSession: session.id)
        store.setRemoteConnection(.connected, forSession: session.id)

        try await settle("classified") { trees.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.remotePresentation?.rowState, .attached)
    }

    func testARowSettledWithAnUnlistedPaneReadsEndedOnHostOnceItsSessionEnds() async throws {
        let session = try row(split: true)
        answers = [try tree(listing: [originLeft]), try tree(listing: nil)]
        let watcher = supervisor()
        watcher.paneExited(try XCTUnwrap(session.splitPaneIdentity), inSession: session.id)
        try await settle("classified") { trees.count == 1 }
        XCTAssertEqual(session.remotePresentation?.rowState, .attached)

        watcher.streamFailed(inSession: session.id)

        try await settle("ended") { session.remotePresentation?.rowState == .endedOnHost }
    }

    func testFailedStreamsOfOneHostShareOneTreeCallAndAnEndedRowIsNotAskedAgain() async throws {
        let first = try row()
        let second = try row()
        answers = [try tree(listing: nil)]
        let watcher = supervisor()

        watcher.streamFailed(inSession: first.id)
        watcher.streamFailed(inSession: second.id)
        try await settle("both ended") {
            first.remotePresentation?.rowState == .endedOnHost && second.remotePresentation?.rowState == .endedOnHost
        }
        watcher.streamFailed(inSession: first.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(trees.count, 1)
    }
}
