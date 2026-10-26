import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerTransferTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    /// Through the protocol, so a signature drift that falls back to the unsupported default fails here.
    private func makeActions(rowBook: RemoteRowBookWriter? = nil) -> any ControlActions {
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                                   identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                                   socketPath: stateDir.appendingPathComponent("control.sock").path)
        server.remoteRowBook = rowBook
        return server
    }

    /// A user-attached remote row with a split, as `insertRemoteRow` leaves it.
    private func remoteRow(in store: AppStore) throws -> (session: Session, leads: [UUID: ZmxLeadAttachment]) {
        let endpoint = ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/zmx-p4linux")
        let origin = RemoteBinding.Origin(host: "p4linux", endpoint: endpoint, sessionName: "build")
        let daemons = (left: ZmxSupport.daemonName(for: UUID()), right: ZmxSupport.daemonName(for: UUID()))
        let leads = (left: ZmxLeadAttachment(claim: true), right: ZmxLeadAttachment(claim: true))
        let primary = try RemoteSession.attachPaneCommand(host: origin.host, endpoint: endpoint, daemon: daemons.left,
                                                          session: origin.sessionName, pane: .left, lead: leads.left)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp",
                                                     command: primary, wait: true, remoteHost: origin.host))
        session.splitInitialCommand = try RemoteSession.attachPaneCommand(
            host: origin.host, endpoint: endpoint, daemon: daemons.right, session: origin.sessionName, pane: .right,
            lead: leads.right)
        session.splitCommandWait = true
        store.setSplitVisibility(session.id, shown: true, axis: .leftRight)
        let split = try XCTUnwrap(session.splitPaneIdentity)
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [session.paneIdentity: daemons.left, split: daemons.right],
                                       presentationVersion: 1, origin: origin),
                         forSession: session.id)
        ZmxLeadBook.shared.begin(leads.left, pane: session.paneIdentity)
        ZmxLeadBook.shared.begin(leads.right, pane: split)
        let panes = [session.paneIdentity, split]
        addTeardownBlock { panes.forEach { ZmxLeadBook.shared.forget(pane: $0) } }
        return (session, [session.paneIdentity: leads.left, split: leads.right])
    }

    private func realizedView(session: Session) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: "/bin/cat")
        view.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        return view
    }

    func testPrepareForTransferFreesALiveSurfaceWithoutReachingThePaneExitHandler() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        let view = realizedView(session: session)
        session.surface = view
        var exitHandled = false
        let sessionID = session.id
        view.onExit = { [weak view] in
            guard let view else { return }
            exitHandled = true
            agtermApp.handlePaneExit(view, store: store, sessionID: sessionID, library: self.library)
        }

        view.prepareForTransfer()
        XCTAssertFalse(view.claimProcessExit(), "the exit is claimed before the surface is freed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.handleProcessExit()

        XCTAssertFalse(view.isRealized)
        XCTAssertFalse(exitHandled)
        XCTAssertNotNil(store.session(withID: sessionID))
    }

    func testAWorkspaceMovesToANewWindowAndAnswersItsIdAndCount() async throws {
        let sourceID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.store(for: sourceID))
        let moved = store.addWorkspace(name: "build")
        let session = try XCTUnwrap(store.addSession(toWorkspace: moved.id, cwd: NSTemporaryDirectory()))

        let response = await makeActions().transferWorkspace(moved.id.uuidString, window: nil, toWindow: "new",
                                                              windowName: "dest")

        XCTAssertTrue(response.ok, response.error ?? "")
        let destination = try XCTUnwrap(response.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertNotEqual(destination, sourceID)
        XCTAssertEqual(response.result?.affected, 1)
        XCTAssertEqual(library.windows.first { $0.id == destination }?.name, "dest")
        XCTAssertEqual(library.store(for: destination)?.workspaces.flatMap(\.sessions).map(\.id), [session.id])
        XCTAssertNil(store.session(withID: session.id))
    }

    func testTheLastWorkspaceMovesAndItsEmptiedWindowIsDeleted() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let source = try XCTUnwrap(library.windowID(for: store))
        let only = try XCTUnwrap(store.workspaces.first)
        let sessions = only.sessions.map(\.id)
        let other = library.newWindow(name: "other")
        // a live NSWindow for the source, as `TitleProbeView` registers it; `isReleasedWhenClosed` false per the
        // hosted-test rule, since the registry outlives the test body
        let sourceWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false
        WindowRegistry.shared.register(source, window: sourceWindow)
        sourceWindow.orderFront(nil)
        addTeardownBlock {
            WindowRegistry.shared.unregister(source)
            sourceWindow.orderOut(nil)
        }
        let sourceFile = stateDir.appendingPathComponent("windows/\(source.uuidString).json")

        let response = await makeActions().transferWorkspace(only.id.uuidString, window: nil, toWindow: "other",
                                                              windowName: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, other.id.uuidString)
        XCTAssertEqual(response.result?.affected, sessions.count)
        XCTAssertFalse(library.windows.map(\.id).contains(source))
        let landed = try XCTUnwrap(library.store(for: other.id)?.workspaces.first { $0.id == only.id })
        XCTAssertEqual(landed.sessions.map(\.id), sessions)
        XCTAssertFalse(sourceWindow.isVisible, "the emptied source window is closed on screen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path), "and its window file stays deleted")
    }

    func testSessionsMoveIntoANamedWorkspaceOfANamedWindow() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        let other = library.newWindow(name: "other")

        let response = await makeActions().transferSessions(
            [session.id.uuidString], window: nil,
            transfer: ControlSessionTransfer(toWindow: "other", workspaceName: "landed"))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, other.id.uuidString)
        let landed = try XCTUnwrap(library.store(for: other.id)?.workspaces.first { $0.name == "landed" })
        XCTAssertEqual(landed.sessions.map(\.id), [session.id])
    }

    func testAMovedRemoteRowAttachesWithAFreshNonceAndNoClaim() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let (session, before) = try remoteRow(in: store)
        let other = library.newWindow(name: "other")

        let response = await makeActions().transferSessions(
            [session.id.uuidString], window: nil, transfer: ControlSessionTransfer(toWindow: "other"))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNotNil(library.store(for: other.id)?.session(withID: session.id))
        let split = try XCTUnwrap(session.splitPaneIdentity)
        let commands = [session.paneIdentity: session.initialCommand, split: session.splitInitialCommand]
        for (pane, old) in before {
            let command = try XCTUnwrap(commands[pane] ?? nil)
            let lead = try XCTUnwrap(ZmxLeadBook.shared.states[pane]?.attachment)
            XCTAssertNotEqual(lead.nonce, old.nonce)
            XCTAssertFalse(lead.claim)
            XCTAssertTrue(command.contains("\(ZmxLeadAttachment.nonceVariable)=\(lead.nonce)"), command)
            XCTAssertFalse(command.contains(old.nonce), command)
            XCTAssertFalse(command.contains(ZmxLeadAttachment.claimVariable), command)
        }
    }

    func testAMovedRemoteRowIsBookedInItsNewWindowAtOnce() async throws {
        let book = RemoteRowBook(directory: stateDir)
        let writer = RemoteRowBookWriter(library: library, book: book, delay: 60)
        let sourceID = try XCTUnwrap(library.activeWindowID)
        let (session, _) = try remoteRow(in: try XCTUnwrap(library.store(for: sourceID)))
        writer.write()
        XCTAssertEqual(book.load().map(\.windowID), [sourceID])
        let other = library.newWindow(name: "other")

        let response = await makeActions(rowBook: writer).transferSessions(
            [session.id.uuidString], window: nil, transfer: ControlSessionTransfer(toWindow: "other"))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(book.load().map(\.windowID), [other.id])
    }
}
