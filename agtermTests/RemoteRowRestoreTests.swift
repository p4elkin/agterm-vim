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

    private func record(window: UUID, workspace: UUID, position: Int, remoteID: String = "R1", parent: String? = nil,
                        transport: RemoteTransport = .ssh) throws -> RemoteRowBook.Record {
        let json = """
        {"windowID":"\(window.uuidString)","workspaceID":"\(workspace.uuidString)","position":\(position),
         "host":"p4linux","endpoint":{"executable":"\(endpoint.executable)","socketDirectory":"\(endpoint.socketDirectory)"},
         "sessionName":"build","remoteSessionID":"\(remoteID)","presentationVersion":1,\(parent.map { #""parentRemoteSessionID":"\#($0)","# } ?? "")
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

    func testASavedCompanionComesBackUnderItsRestoredParent() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let records = [try record(window: window, workspace: workspace, position: 0),
                       try record(window: window, workspace: workspace, position: 1, remoteID: "C1", parent: "R1")]

        server.restoreRemoteRows(records, windowID: window, store: store)

        let parent = try XCTUnwrap(remoteRows(store).first { $0.remotePresentation?.binding.remoteSessionID == "R1" })
        let companion = try XCTUnwrap(remoteRows(store).first { $0.remotePresentation?.binding.remoteSessionID == "C1" })
        XCTAssertNil(parent.parentID)
        XCTAssertEqual(companion.parentID, parent.id)
        remoteRows(store).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }

    func testASavedCompanionAheadOfItsParentStillComesBackUnderIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let records = [try record(window: window, workspace: workspace, position: 0, remoteID: "C1", parent: "R1"),
                       try record(window: window, workspace: workspace, position: 1)]

        server.restoreRemoteRows(records, windowID: window, store: store)

        let parent = try XCTUnwrap(remoteRows(store).first { $0.remotePresentation?.binding.remoteSessionID == "R1" })
        let companion = try XCTUnwrap(remoteRows(store).first { $0.remotePresentation?.binding.remoteSessionID == "C1" })
        XCTAssertEqual(companion.parentID, parent.id)
        remoteRows(store).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }

    func testDeferringACompanionKeepsTheOtherRowsInTheirSavedOrder() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let local = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp"))
        let records = [try record(window: window, workspace: workspace, position: 0, remoteID: "C1", parent: "R1"),
                       try record(window: window, workspace: workspace, position: 1),
                       try record(window: window, workspace: workspace, position: 2, remoteID: "R2")]

        server.restoreRemoteRows(records, windowID: window, store: store)

        let order = try XCTUnwrap(store.workspaces.first { $0.id == workspace }?.sessions).map {
            $0.remotePresentation?.binding.remoteSessionID ?? ($0.id == local.id ? "local" : "other")
        }
        XCTAssertEqual(order, ["R1", "C1", "R2", "other", "local"])
        remoteRows(store).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }

    func testCompanionsDeferredForOneParentKeepTheirSavedOrder() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let records = [try record(window: window, workspace: workspace, position: 0, remoteID: "C1", parent: "R1"),
                       try record(window: window, workspace: workspace, position: 1, remoteID: "C2", parent: "R1"),
                       try record(window: window, workspace: workspace, position: 2)]

        server.restoreRemoteRows(records, windowID: window, store: store)

        XCTAssertEqual(remoteRows(store).map { $0.remotePresentation?.binding.remoteSessionID }, ["R1", "C1", "C2"])
        remoteRows(store).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }

    func testASavedCompanionWithoutASingleParentInItsWorkspaceComesBackTopLevel() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let home = try XCTUnwrap(store.currentWorkspaceID)
        let other = store.addWorkspace(name: "other").id
        for _ in 0..<2 {
            let twin = try XCTUnwrap(store.addSession(toWorkspace: home, cwd: "/tmp", remoteHost: "p4linux"))
            store.bindRemote(RemoteBinding(remoteSessionID: "R5", daemonsByLocalPane: [:], presentationVersion: 1,
                                           origin: RemoteBinding.Origin(host: "p4linux", endpoint: endpoint, sessionName: "twin")),
                             forSession: twin.id)
        }
        let restores: [RemoteRowBook.Record] = [
            try record(window: window, workspace: home, position: 0, remoteID: "C1", parent: "R9"),
            try record(window: window, workspace: other, position: 0),
            try record(window: window, workspace: home, position: 0, remoteID: "C2", parent: "R1"),
            try record(window: window, workspace: home, position: 0, remoteID: "C3", parent: "R5"),
        ]
        for record in restores {
            server.restoreRemoteRows([record], windowID: window, store: store)
        }

        for id in ["C1", "C2", "C3"] {
            let row = try XCTUnwrap(remoteRows(store).first { $0.remotePresentation?.binding.remoteSessionID == id }, id)
            XCTAssertNil(row.parentID, id)
        }
        remoteRows(store).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }

    func testARecordWithoutANameRestoresTheAttachTimeName() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)

        server.restoreRemoteRows([try record(window: window, workspace: workspace, position: 0)], windowID: window, store: store)

        let row = try XCTUnwrap(remoteRows(store).first)
        XCTAssertEqual(row.customName, "build")
        XCTAssertEqual(row.remotePresentation?.namePending, false)
        ZmxLeadBook.shared.forget(pane: row.paneIdentity)
    }

    func testASavedNameAndAPendingRenameComeBack() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        var record = try record(window: window, workspace: workspace, position: 0)
        record.name = RemoteRowBook.Record.Name(value: "labels preservation", pending: true)

        server.restoreRemoteRows([record], windowID: window, store: store)

        let row = try XCTUnwrap(remoteRows(store).first)
        XCTAssertEqual(row.customName, "labels preservation")
        XCTAssertEqual(row.remotePresentation?.namePending, true)
        XCTAssertEqual(row.remotePresentation?.binding.origin?.sessionName, "build")
        ZmxLeadBook.shared.forget(pane: row.paneIdentity)
    }

    func testARowSavedWithoutACustomNameComesBackWithout() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        var record = try record(window: window, workspace: workspace, position: 0)
        record.name = RemoteRowBook.Record.Name(value: nil, pending: false)

        server.restoreRemoteRows([record], windowID: window, store: store)

        let row = try XCTUnwrap(remoteRows(store).first)
        XCTAssertNil(row.customName)
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
