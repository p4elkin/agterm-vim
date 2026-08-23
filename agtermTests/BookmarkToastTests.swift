import AppKit
import XCTest
@testable import agterm
import agtermCore

/// The toast on `session.bookmark add` shares the session's single overlay slot, so it can lose the slot to
/// a caller's program or panel; these pin that the add never fails or evicts anything because of it.
@MainActor
final class BookmarkToastTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-bookmark-toast-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            let actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func makeMarkedSession() throws -> (AppStore, Session, Int) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let turn = try XCTUnwrap(store.markTurn(session.id))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: ControlServer.bodyFile(for: session.id)) }
        return (store, session, turn)
    }

    func testAddOpensAToastNamingTheTurn() throws {
        let (_, session, turn) = try makeMarkedSession()

        let response = server.addSessionBookmark(session.id.uuidString, window: nil, turn: nil, prompt: "fix it")

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(session.hudActive)
        XCTAssertTrue(try XCTUnwrap(session.hudSpec).message.contains(TurnMark.needle(for: turn)))
    }

    func testAddWhoseToastCannotOpenStillSucceeds() throws {
        let (store, session, _) = try makeMarkedSession()
        XCTAssertTrue(store.openOverlay(session.id, command: "true"))

        let response = server.addSessionBookmark(session.id.uuidString, window: nil, turn: nil, prompt: "fix it")

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(library.bookmarks.list(sessionID: session.id).count, 1)
        XCTAssertNil(session.hudSpec, "the running program must keep the slot")
        XCTAssertTrue(session.programOverlayActive)
    }

    func testAddDoesNotReplaceACallersHud() throws {
        let (_, session, _) = try makeMarkedSession()
        let callers = HudSpec(message: "gathering options", spinner: .braille)
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: callers).ok)

        let response = server.addSessionBookmark(session.id.uuidString, window: nil, turn: nil, prompt: "fix it")

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(library.bookmarks.list(sessionID: session.id).count, 1)
        XCTAssertEqual(session.hudSpec, callers, "a transient toast must not evict a caller's panel")
    }
}
