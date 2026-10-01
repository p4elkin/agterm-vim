import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteRowRestoreTests: XCTestCase {
    @MainActor
    private final class Transport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            func send(_ line: Data) {}
            func stop() {}
        }

        var launches: [[String]] = []

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            launches.append(argv)
            return Link()
        }
    }

    private var directory: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var transport: Transport!
    private let daemon = ZmxSupport.daemonName(for: UUID())
    private let endpoint = ControlZmxEndpoint(executable: "/opt/agterm-headless/zmx", socketDirectory: "/tmp/zmx-saved")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-rowrestore-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        server = ControlServer(library: library, actions: AppActions(library: library),
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: directory)),
                               identity: AppIdentity(version: "9.9.9"),
                               socketPath: "/tmp/agterm-rr-\(UUID().uuidString.prefix(8)).sock")
        transport = Transport()
        server.remoteTransport = transport
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(window: UUID, workspace: UUID, position: Int, transport: RemoteTransport = .ssh) throws -> RemoteRowBook.Record {
        let json = """
        {"windowID":"\(window.uuidString)","workspaceID":"\(workspace.uuidString)","position":\(position),
         "host":"p4linux","endpoint":{"executable":"\(endpoint.executable)","socketDirectory":"\(endpoint.socketDirectory)"},
         "sessionName":"build","remoteSessionID":"R1","presentationVersion":1,
         "transport":\(String(decoding: try JSONEncoder().encode(transport), as: UTF8.self)),
         "daemonsByPane":["left","\(daemon)"],"splitAxis":"vertical"}
        """
        return try JSONDecoder().decode(RemoteRowBook.Record.self, from: Data(json.utf8))
    }

    private func remoteRows(_ store: AppStore) -> [Session] {
        store.workspaces.flatMap(\.sessions).filter { $0.remoteHost != nil }
    }

    func testASavedRowComesBackInPlaceUnselectedBoundAndStreaming() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp"))
        _ = store.addSession(toWorkspace: workspace, cwd: "/tmp")
        store.selectSession(first.id)

        server.restoreRemoteRows([try record(window: window, workspace: workspace, position: 1)], windowID: window, store: store)

        let row = try XCTUnwrap(remoteRows(store).first)
        let sessions = try XCTUnwrap(store.workspaces.first { $0.id == workspace }?.sessions)
        XCTAssertEqual(sessions.firstIndex { $0 === row }, 1)
        XCTAssertEqual(store.selectedSessionID, first.id)
        XCTAssertEqual(row.remotePresentation?.binding.remoteSessionID, "R1")
        XCTAssertEqual(row.remotePresentation?.binding.origin?.endpoint, endpoint)
        let command = try XCTUnwrap(row.initialCommand)
        XCTAssertTrue(command.contains(endpoint.socketDirectory))
        XCTAssertTrue(command.contains(daemon))
        XCTAssertFalse(command.contains(ZmxLeadAttachment.claimVariable), "a restored row claims no lead")
        XCTAssertEqual(transport.launches.count, 1)
        ZmxLeadBook.shared.forget(pane: row.paneIdentity)
    }

    func testAMoshRecordRestoresAMoshRow() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let mosh = RemoteTransport.mosh(server: "/usr/bin/mosh-server", client: nil)

        server.restoreRemoteRows([try record(window: window, workspace: workspace, position: 0, transport: mosh)],
                                 windowID: window, store: store)

        let row = try XCTUnwrap(remoteRows(store).first)
        XCTAssertTrue(try XCTUnwrap(row.initialCommand).contains("--server=/usr/bin/mosh-server"))
        XCTAssertEqual(row.remotePresentation?.binding.origin?.transport, mosh)
        ZmxLeadBook.shared.forget(pane: row.paneIdentity)
    }

    func testNothingIsCreatedTwice() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let records = [try record(window: window, workspace: try XCTUnwrap(store.currentWorkspaceID), position: 0)]

        server.restoreRemoteRows(records, windowID: window, store: store)
        server.restoreRemoteRows(records, windowID: window, store: store)

        XCTAssertEqual(remoteRows(store).count, 1)
        remoteRows(store).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }

    func testLaunchRestoresEachOpenWindowOnceFromTheBook() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let book = RemoteRowBook(directory: directory)
        try book.save([try record(window: window, workspace: try XCTUnwrap(store.currentWorkspaceID), position: 0)])

        server.restoreRemoteRows(from: book)

        XCTAssertEqual(remoteRows(store).count, 1)
        remoteRows(store).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }

    func testReopeningAClosedWindowRecreatesItsRemoteRow() throws {
        let window = library.newWindow(name: "other").id
        let workspace = try XCTUnwrap(library.loadStore(for: window)?.currentWorkspaceID)
        let book = RemoteRowBook(directory: directory)
        try book.save([try record(window: window, workspace: workspace, position: 0)])
        library.closeWindow(window)
        library.onStoreLoaded = { [server] id, store in server?.restoreRemoteRows(book.load(), windowID: id, store: store) }

        let reopened = try XCTUnwrap(library.loadStore(for: window))

        XCTAssertEqual(remoteRows(reopened).count, 1)
        remoteRows(reopened).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }
}
