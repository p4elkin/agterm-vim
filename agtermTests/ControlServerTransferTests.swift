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
    private func makeActions() -> any ControlActions {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                      socketPath: stateDir.appendingPathComponent("control.sock").path)
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.handleProcessExit()

        XCTAssertFalse(view.isRealized)
        XCTAssertFalse(exitHandled)
        XCTAssertFalse(view.claimProcessExit(), "the exit is claimed before the surface is freed")
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

    func testARefusedMoveAnswersTheRefusalAndChangesNothing() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let only = try XCTUnwrap(store.workspaces.first)
        _ = library.newWindow(name: "other")
        let windows = library.windows.map(\.id)

        let response = await makeActions().transferWorkspace(only.id.uuidString, window: nil, toWindow: "other",
                                                              windowName: nil)

        XCTAssertEqual(response.error, "last workspace in window")
        XCTAssertEqual(library.windows.map(\.id), windows)
        XCTAssertEqual(store.workspaces.map(\.id), [only.id])
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

    func testASessionMoveNamingBothAWorkspaceAndAWorkspaceNameIsRefused() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        _ = library.newWindow(name: "other")

        let response = await makeActions().transferSessions(
            [session.id.uuidString], window: nil,
            transfer: ControlSessionTransfer(toWindow: "other", workspace: "active", workspaceName: "landed"))

        XCTAssertEqual(response.error, "a workspace and --workspace-name are exclusive")
        XCTAssertNotNil(store.session(withID: session.id))
    }
}
