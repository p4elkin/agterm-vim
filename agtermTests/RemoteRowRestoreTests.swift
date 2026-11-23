import XCTest
@testable import agterm
@testable import agtermCore

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

    private final class Runner: RemoteCommandRunner, @unchecked Sendable {
        func run(_ argv: [String], deadline: TimeInterval) async -> RemoteCommandResult {
            RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
    }

    private var directory: URL!
    private var pools: SshHostPools!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var transport: Transport!
    private let daemon = ZmxSupport.daemonName(for: UUID())
    private let endpoint = ControlZmxEndpoint(executable: "/opt/agterm-headless/zmx", socketDirectory: "/tmp/zmx-saved")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-rowrestore-\(UUID().uuidString)")
        pools = SshHostPools(root: "/tmp/agterm-ssh-test", owner: directory.path, runner: Runner())
        library = WindowLibrary(directory: directory, paneFinalizer: nil, sshHostPools: pools)
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
        pools = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(window: UUID, workspace: UUID, position: Int, remoteID: String = "R1", parent: String? = nil,
                        left: String? = nil, right: String? = nil) throws -> RemoteRowBook.Record {
        let json = recordJSON(window: window, workspace: workspace, position: position, remoteID: remoteID, parent: parent,
                              left: left, right: right)
        return try JSONDecoder().decode(RemoteRowBook.Record.self, from: Data(json.utf8))
    }

    /// recordJSON is a record as a file holds it; `transport` is the key an older build wrote.
    private func recordJSON(window: UUID, workspace: UUID, position: Int, remoteID: String = "R1", parent: String? = nil,
                            transport: String = #"{"ssh":{}}"#, left: String? = nil, right: String? = nil) -> String {
        let panes = ["\"left\",\"\(left ?? daemon)\""] + (right.map { ["\"right\",\"\($0)\""] } ?? [])
        return """
        {"windowID":"\(window.uuidString)","workspaceID":"\(workspace.uuidString)","position":\(position),
         "host":"p4linux","endpoint":{"executable":"\(endpoint.executable)","socketDirectory":"\(endpoint.socketDirectory)"},
         "sessionName":"build","remoteSessionID":"\(remoteID)","presentationVersion":1,\(parent.map { #""parentRemoteSessionID":"\#($0)","# } ?? "")
         "transport":\(transport),
         "daemonsByPane":[\(panes.joined(separator: ","))],"splitAxis":"vertical"}
        """
    }

    private func remoteRows(_ store: AppStore) -> [Session] {
        store.workspaces.flatMap(\.sessions).filter { $0.remoteHost != nil }
    }

    private func wake(_ row: Session, in store: AppStore) {
        library.onRowWake = { [weak server] in server?.renewAttachLines(for: $0) }
        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
    }

    private func assertAsleepWithNothingSpawned(_ rows: [Session], file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            XCTAssertTrue(row.asleep, file: file, line: line)
            XCTAssertNil(row.initialCommand, file: file, line: line)
            XCTAssertNil(row.splitInitialCommand, file: file, line: line)
            XCTAssertNil(row.surface, file: file, line: line)
            XCTAssertNil(row.splitSurface, file: file, line: line)
            for pane in [row.paneIdentity] + (row.splitPaneIdentity.map { [$0] } ?? []) {
                XCTAssertNil(ZmxLeadBook.shared.states[pane], "no lead begins for a sleeping pane", file: file, line: line)
            }
        }
    }

    private func launches(_ count: Int) async throws {
        for _ in 0..<250 where transport.launches.count < count { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(transport.launches.count, count)
    }

    func testAForkPathRestoreOfThreeRowsInsertsThemAllAsleepWithOnlyTheirStreams() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let records = [try record(window: window, workspace: workspace, position: 0, remoteID: "R1"),
                       try record(window: window, workspace: workspace, position: 1, remoteID: "R2",
                                  right: ZmxSupport.daemonName(for: UUID())),
                       try record(window: window, workspace: workspace, position: 2, remoteID: "R3")]

        server.restoreRemoteRows(records, windowID: window, store: store)

        let rows = remoteRows(store)
        XCTAssertEqual(rows.count, 3)
        XCTAssertNotNil(rows.first { $0.remoteSessionID == "R2" }?.splitPaneIdentity)
        assertAsleepWithNothingSpawned(rows)
        try await launches(3)
        let pool = pools.pool(for: "p4linux")
        XCTAssertEqual(pool.load, [3])
        rows.forEach { _ = pool.lease("present:\($0.id)") }
        XCTAssertEqual(pool.load, [3], "the three users are the streams")
    }

    func testAnUnaddressableForkPathRecordIsRefusedNotInsertedAsleep() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)

        server.restoreRemoteRows([try record(window: window, workspace: workspace, position: 0, left: "not-a-daemon")],
                                 windowID: window, store: store)

        XCTAssertTrue(remoteRows(store).isEmpty)
        XCTAssertTrue(transport.launches.isEmpty)
    }

    func testWakingARestoredRowWhoseDaemonIsGoneGivesTheEndedLine() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        server.restoreRemoteRows([try record(window: window, workspace: try XCTUnwrap(store.currentWorkspaceID), position: 0)],
                                 windowID: window, store: store)
        let row = try XCTUnwrap(remoteRows(store).first)
        let binding = try XCTUnwrap(row.remotePresentation?.binding)
        row.remotePresentation?.binding = RemoteBinding(remoteSessionID: binding.remoteSessionID, daemonsByLocalPane: [:],
                                                        presentationVersion: binding.presentationVersion, origin: binding.origin)

        wake(row, in: store)

        XCTAssertFalse(row.asleep)
        XCTAssertEqual(row.initialCommand, RemoteSession.endedCommand(host: "p4linux"))
    }

    func testASavedRowComesBackInPlaceUnselectedBoundAndStreaming() async throws {
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
        assertAsleepWithNothingSpawned([row])
        wake(row, in: store)
        let command = try XCTUnwrap(row.initialCommand)
        XCTAssertTrue(command.contains(endpoint.socketDirectory))
        XCTAssertTrue(command.contains(daemon))
        XCTAssertFalse(command.contains(ZmxLeadAttachment.claimVariable), "a restored row claims no lead")
        try await launches(1)
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

    func testABookHoldingAMoshRecordRestoresOnlyItsOtherRows() throws {
        let store = try XCTUnwrap(library.activeStore)
        let window = try XCTUnwrap(library.activeWindowID)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let book = RemoteRowBook(directory: directory)
        let ssh = recordJSON(window: window, workspace: workspace, position: 0, remoteID: "R1")
        let mosh = recordJSON(window: window, workspace: workspace, position: 1, remoteID: "R2",
                              transport: #"{"mosh":{"server":"/usr/bin/mosh-server"}}"#,
                              left: ZmxSupport.daemonName(for: UUID()))
        try Data("[\(ssh),\(mosh)]".utf8).write(to: book.fileURL)

        server.restoreRemoteRows(from: book)

        let rows = remoteRows(store)
        XCTAssertEqual(rows.compactMap { $0.remotePresentation?.binding.remoteSessionID }, ["R1"])
        rows.forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
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
        assertAsleepWithNothingSpawned(remoteRows(reopened))
        remoteRows(reopened).forEach { ZmxLeadBook.shared.forget(pane: $0.paneIdentity) }
    }
}
