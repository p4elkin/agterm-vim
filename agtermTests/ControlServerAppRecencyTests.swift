import XCTest
@testable import agterm
import agtermCore

/// `tree` carries the library's app-wide visit list whichever window it projects.
@MainActor
final class ControlServerAppRecencyTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-app-recency-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeServer() -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                      socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    /// Selects a second session of `window`'s first workspace while `window` is frontmost: a visit.
    private func visit(_ window: UUID) throws -> UUID {
        let store = try XCTUnwrap(library.store(for: window))
        let workspace = try XCTUnwrap(store.workspaces.first)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: NSTemporaryDirectory(), select: false))
        library.frontmostWindowID = window
        _ = store.selectSession(session.id)
        return session.id
    }

    func testEveryWindowsTreeCarriesTheSameVisitsWithTheirWindows() throws {
        let first = try XCTUnwrap(library.activeWindowID)
        let second = library.newWindow(name: "other").id
        let visitedFirst = try visit(first)
        let visitedSecond = try visit(second)
        let server = makeServer()

        let frontmost = try XCTUnwrap(server.controlTree(window: nil).result?.tree?.appSessionRecency)
        let projected = try XCTUnwrap(server.controlTree(window: first.uuidString).result?.tree?.appSessionRecency)

        XCTAssertEqual(frontmost, projected)
        XCTAssertEqual(frontmost.first, ControlRecentSession(session: visitedFirst.uuidString, window: first.uuidString))
        XCTAssertFalse(frontmost.contains { $0.session == visitedSecond.uuidString }, "the active session is dropped")
    }
}
