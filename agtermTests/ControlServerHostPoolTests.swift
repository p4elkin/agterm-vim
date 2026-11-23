import XCTest
@testable import agterm
@testable import agtermCore

@MainActor
final class ControlServerHostPoolTests: XCTestCase {
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")
    private struct Timeout: Error {}

    /// Answers every ssh call without running one; `connections` decides whether a pool's master check and start succeed.
    private final class Runner: RemoteCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        private var connectionsUp = true
        private let versions: String = {
            var result = ControlResult()
            result.versions = CatalogVersions(server: "1", protocolVersion: 1, catalog: 1)
            result.app = AppIdentity(version: "9.9.9", commit: "testsha")
            return String(decoding: (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data(), as: UTF8.self)
        }()

        var argvs: [[String]] { lock.withLock { recorded } }
        var connections: Bool {
            get { lock.withLock { connectionsUp } }
            set { lock.withLock { connectionsUp = newValue } }
        }

        func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
            lock.withLock { recorded.append(argv) }
            if argv.contains("-O") || argv.first == "/bin/sh" {
                return RemoteCommandResult(status: connections ? 0 : 255, stdout: "", stderr: "")
            }
            if argv.last?.contains("agtermctl") == true, argv.last?.contains("version") == true {
                return RemoteCommandResult(status: 0, stdout: versions, stderr: "")
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
    }

    private final class Transport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            func send(_: Data) {}
            func stop() {}
        }

        var launches: [[String]] = []
        var catalog: (@MainActor (Data) -> Void)?

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose _: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            if argv.last?.contains("catalog subscribe") == true { catalog = onLine }
            launches.append(argv)
            return Link()
        }
    }

    private var stateDir: URL!
    private var pools: SshHostPools!
    private var library: WindowLibrary!
    private var runner: Runner!
    private var transport: Transport!
    private var server: ControlServer!
    private var panes: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-host-pool-tests-\(UUID().uuidString)", isDirectory: true)
        runner = Runner()
        pools = SshHostPools(root: "/tmp/agterm-ssh-test", owner: stateDir.path, runner: runner)
        library = WindowLibrary(directory: stateDir, paneFinalizer: nil, sshHostPools: pools)
        transport = Transport()
        server = makeServer(library)
    }

    override func tearDown() async throws {
        server?.stopRemotePresentations()
        server?.stopRemoteCatalogs()
        for pane in panes {
            ZmxLeadBook.shared.forget(pane: pane)
            RemoteReconnectBook.shared.cancel(pane: pane)
        }
        panes = []
        PaneLead.catalogChannel = nil
        library?.finalizeAllPendingCloses()
        server = nil
        library = nil
        pools = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeServer(_ library: WindowLibrary) -> ControlServer {
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteTransport = transport
        return server
    }

    private var store: AppStore {
        get throws { try XCTUnwrap(library.activeStore) }
    }

    private func remoteRow(host: String = "p4linux", transport: RemoteTransport = .ssh, left: String? = nil, split: Bool = false,
                           primary: UUID = UUID()) -> RemoteRow {
        RemoteRow(host: host, endpoint: Self.endpoint, sessionName: "build", remoteSessionID: "s-\(UUID().uuidString)",
                  presentationVersion: 1, transport: transport, left: left ?? ZmxSupport.daemonName(for: primary),
                  right: split ? ZmxSupport.daemonName(for: UUID()) : nil, splitAxis: nil, name: "build", namePending: false)
    }

    private func insert(_ row: RemoteRow) throws -> Session {
        let store = try store
        let placement = ControlServer.RemotePlacement(store: store, workspace: try XCTUnwrap(store.currentWorkspaceID))
        guard case .inserted(let session) = server.insertRemoteRow(row, at: placement, claim: false) else {
            throw Timeout()
        }
        panes += [session.paneIdentity] + (session.splitPaneIdentity.map { [$0] } ?? [])
        return session
    }

    private func path(_ host: String, _ user: String) -> String { pools.pool(for: host).lease(user) }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Timeout()
    }

    func testRowsOnOneHostShareAPoolAndAnotherHostGetsItsOwn() throws {
        let one = try insert(remoteRow())
        let two = try insert(remoteRow())
        let other = try insert(remoteRow(host: "mini"))

        let pool = try XCTUnwrap(server.sshPool(forSession: one.id))
        XCTAssertTrue(server.sshPool(forSession: two.id) === pool)
        XCTAssertTrue(server.sshPool(forSession: other.id) === pools.pool(for: "mini"))
        XCTAssertFalse(server.sshPool(forSession: other.id) === pool)
    }

    func testAMoshRowAndALocalRowHaveNoPool() throws {
        let mosh = try insert(remoteRow(transport: .mosh(server: nil, client: nil)))
        let local = try XCTUnwrap(try store.addSession(toWorkspace: try XCTUnwrap(try store.currentWorkspaceID), cwd: "/tmp"))

        XCTAssertNil(server.sshPool(forSession: mosh.id))
        XCTAssertNil(server.sshPool(forSession: local.id))
    }

    func testACatalogRowRidesItsWindowsPool() async throws {
        server.wireRemoteCatalogs()
        let window = library.newRemoteWindow(host: "box").id
        try await until { self.transport.catalog != nil }
        let rowID = UUID()
        let pane = CatalogPane(identity: UUID(), daemon: ZmxSupport.daemonName(for: UUID()), endpoint: Self.endpoint)
        panes.append(pane.identity)
        var line = try CatalogCodec.encode(.snapshot(CatalogSnapshot(
            epoch: "e1", rev: 0, catalogID: UUID(), versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
            workspaces: [CatalogWorkspace(id: UUID(), name: "main", sessions: [CatalogSession(
                fields: CatalogSessionFields(id: rowID, name: "build", parent: nil, cwd: "/srv", primary: pane.identity,
                                             axis: nil, shown: false, lifecycle: .live),
                panes: [pane])])])))
        if line.last == UInt8(ascii: "\n") { line.removeLast() }
        transport.catalog?(line)
        XCTAssertNotNil(library.store(for: window)?.session(withID: rowID))

        let pool = try XCTUnwrap(server.catalogPool(forSession: rowID))
        XCTAssertTrue(server.sshPool(forSession: rowID) === pool)
        XCTAssertNil(pools.pools["box"])
    }

    func testAMoshRowIsInsertedWithNoControlPath() throws {
        let row = try insert(remoteRow(transport: .mosh(server: nil, client: nil), split: true))

        let left = try XCTUnwrap(row.initialCommand)
        let right = try XCTUnwrap(row.splitInitialCommand)
        XCTAssertTrue(left.contains("mosh"), left)
        XCTAssertFalse(left.contains("ControlPath"), left)
        XCTAssertFalse(right.contains("ControlPath"), right)
        XCTAssertNil(pools.pools["p4linux"])
    }

    func testAnUnaddressableRowIsRefusedAndNothingIsInsertedOrLeased() throws {
        let store = try store
        let before = store.workspaces.flatMap(\.sessions).count
        let placement = ControlServer.RemotePlacement(store: store, workspace: try XCTUnwrap(store.currentWorkspaceID))

        guard case .refused(let response) = server.insertRemoteRow(remoteRow(left: "not-a-daemon"), at: placement, claim: false) else {
            return XCTFail("an unaddressable row was inserted")
        }

        XCTAssertFalse(response.ok)
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).count, before)
        XCTAssertNil(pools.pools["p4linux"])
    }

    func testAnSshRowsPanesAndStreamRideItsHostPool() async throws {
        let row = try insert(remoteRow(split: true))
        let split = try XCTUnwrap(row.splitPaneIdentity)

        let left = try XCTUnwrap(row.initialCommand)
        let right = try XCTUnwrap(row.splitInitialCommand)
        XCTAssertTrue(left.contains("ControlPath=\(path("p4linux", "pane:\(row.paneIdentity)"))"), left)
        XCTAssertTrue(right.contains("ControlPath=\(path("p4linux", "pane:\(split)"))"), right)
        XCTAssertFalse(left.contains("ControlPath=none"), left)
        XCTAssertTrue(left.contains(ZmxLeadBook.shared.states[row.paneIdentity]?.attachment.nonce ?? "missing"), left)
        try await until { !self.transport.launches.isEmpty }
        let present = try XCTUnwrap(transport.launches.first)
        XCTAssertTrue(present.contains("ControlPath=" + path("p4linux", "present:\(row.id)")), "\(present)")
        XCTAssertFalse(present.contains("ControlPath=none"), "\(present)")
        XCTAssertEqual(pools.pool(for: "p4linux").load, [3])
    }

    func testAPooledProbeLeasesOnceAndReleasesAfterItRuns() async throws {
        let row = try insert(remoteRow())
        let view = surface(for: row)
        let pool = pools.pool(for: "p4linux")
        let before = pool.load
        let slot = path("p4linux", "pane:\(row.paneIdentity)")
        server.waitToReconnect(view, cover: false, reclaim: nil)

        server.tickReconnects()
        try await until { RemoteReconnectBook.shared.entries[row.paneIdentity]?.probing == false }

        let probes = runner.argvs.filter { $0.last == "true" }
        XCTAssertEqual(probes.count, 1)
        XCTAssertTrue(probes.first?.contains("ControlPath=" + slot) == true, "\(probes)")
        XCTAssertEqual(pool.load, before)
    }

    func testAProbeWhoseConnectionCannotStartFailsWithoutRunningSsh() async throws {
        let row = try insert(remoteRow())
        let view = surface(for: row)
        runner.connections = false
        let pool = pools.pool(for: "p4linux")
        let before = pool.load
        server.waitToReconnect(view, cover: false, reclaim: nil)

        server.tickReconnects()
        try await until { RemoteReconnectBook.shared.entries[row.paneIdentity]?.probing == false }

        XCTAssertTrue(runner.argvs.filter { $0.last == "true" }.isEmpty, "\(runner.argvs)")
        XCTAssertTrue(RemoteReconnectBook.shared.waiting(pane: row.paneIdentity))
        XCTAssertEqual(pool.load, before)
    }

    func testARenewedLineKeepsItsPanesSlot() async throws {
        let row = try insert(remoteRow(split: true))
        let split = try XCTUnwrap(row.splitPaneIdentity)
        let old = try XCTUnwrap(row.initialCommand)
        _ = library.newWindow(name: "other")

        let response = await server.transferSessions([row.id.uuidString], window: nil,
                                                     transfer: ControlSessionTransfer(toWindow: "other"))

        XCTAssertTrue(response.ok, response.error ?? "")
        let left = try XCTUnwrap(row.initialCommand)
        XCTAssertNotEqual(left, old)
        XCTAssertTrue(left.contains("ControlPath=\(path("p4linux", "pane:\(row.paneIdentity)"))"), left)
        XCTAssertTrue(row.splitInitialCommand?.contains("ControlPath=\(path("p4linux", "pane:\(split)"))") == true)
        XCTAssertEqual(pools.pool(for: "p4linux").load, [3])
    }

    func testAReattachLineKeepsItsPanesSlot() throws {
        PaneLead.catalogChannel = { [weak server] session, user in server?.sshPool(forSession: session)?.lease(user) }
        let row = try insert(remoteRow())
        let view = surface(for: row)

        let launch = try XCTUnwrap(PaneReattach.launch(replacing: view, session: row, identity: row.paneIdentity,
                                                       lead: ZmxLeadAttachment(claim: true)))

        XCTAssertTrue(launch.command.contains("ControlPath=\(path("p4linux", "pane:\(row.paneIdentity)"))"), launch.command)
        XCTAssertEqual(pools.pool(for: "p4linux").load, [2])
    }

    func testAnOriginScratchAttachAndItsReattachKeepTheClientsSlot() throws {
        PaneLead.catalogChannel = { [weak server] session, user in server?.sshPool(forSession: session)?.lease(user) }
        let primary = UUID()
        let row = try insert(remoteRow(primary: primary))
        let scratch = UUID()
        try store.applyRemoteLayout(PresentationLayout(panes: [primary], primary: primary, shown: false, scratch: scratch,
                                                       scratchShown: true), forSession: row.id, attach: server)
        let client = try XCTUnwrap(row.scratchClientIdentity)
        panes.append(client)
        let slot = path("p4linux", "pane:\(client)")
        let attach = try XCTUnwrap(row.scratchCommand)
        XCTAssertTrue(attach.contains("ControlPath=\(slot)"), attach)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), env: ["AGTERM_PANE_ID": client.uuidString],
                                      backedByZmx: false)

        let launch = try XCTUnwrap(PaneReattach.originScratch(replacing: view, session: row, identity: scratch,
                                                              lead: ZmxLeadAttachment(claim: false)))

        XCTAssertTrue(launch.command.contains("ControlPath=\(slot)"), launch.command)
        XCTAssertTrue(launch.command.contains(ZmxSupport.daemonName(for: scratch)), launch.command)
        XCTAssertEqual(pools.pool(for: "p4linux").load, [3])
    }

    func testTheTickReleasesAClosedRowsPaneAndStreamUsers() async throws {
        let row = try insert(remoteRow(split: true))
        let kept = try insert(remoteRow())
        let pool = pools.pool(for: "p4linux")
        XCTAssertEqual(pool.load, [5])

        _ = try store.closeSession(row.id)
        server.stopRemotePresentation(row.id)
        server.tickReconnects()

        XCTAssertEqual(pool.load, [2])
        XCTAssertNotNil(server.sshPool(forSession: kept.id))
    }

    func testTheTickKeepsAPendingCloseRowsUsersForUndo() throws {
        let row = try insert(remoteRow(split: true))
        let pool = pools.pool(for: "p4linux")

        XCTAssertTrue(try store.softCloseSession(row.id))
        server.tickReconnects()

        XCTAssertEqual(pool.load, [3])
        XCTAssertTrue(server.sshPool(forSession: row.id) === pool)
    }

    func testTheTickKeepsAnOriginScratchUserUntilTheScratchGoes() throws {
        let primary = UUID()
        let row = try insert(remoteRow(primary: primary))
        let pool = pools.pool(for: "p4linux")
        try store.applyRemoteLayout(PresentationLayout(panes: [primary], primary: primary, shown: false, scratch: UUID(),
                                                       scratchShown: true), forSession: row.id, attach: server)
        let client = try XCTUnwrap(row.scratchClientIdentity)
        panes.append(client)

        server.tickReconnects()
        XCTAssertEqual(pool.load, [3])

        try store.applyRemoteLayout(PresentationLayout(panes: [primary], primary: primary, shown: false, scratch: nil,
                                                       scratchShown: false), forSession: row.id, attach: server)
        XCTAssertNil(row.originScratch)
        server.tickReconnects()
        XCTAssertEqual(pool.load, [2])
    }

    func testTheTickReleasesAnEndedRowsPanesAndKeepsItsStream() throws {
        let row = try insert(remoteRow(split: true))
        let pool = pools.pool(for: "p4linux")

        row.ended = true
        server.tickReconnects()

        XCTAssertEqual(pool.load, [1])
    }

    func testTheTickRetainsOnceMoreWhenItStops() throws {
        let row = try insert(remoteRow())
        let pool = pools.pool(for: "p4linux")
        XCTAssertTrue(server.remoteTickOnce())

        _ = try store.closeSession(row.id)
        server.stopRemotePresentation(row.id)

        XCTAssertFalse(server.remoteTickOnce())
        XCTAssertNil(server.remoteTick)
        XCTAssertEqual(pool.load, [0])
    }

    func testStoppingEveryStreamReleasesTheStreamUsers() throws {
        _ = try insert(remoteRow())
        let pool = pools.pool(for: "p4linux")

        server.stopRemotePresentations()

        XCTAssertEqual(pool.load, [1])
    }

    func testASleepReleasesItsPaneUsersAtTheTickAndAWakeLeasesThemAgain() throws {
        library.onRowWake = { [weak server] in server?.renewAttachLines(for: $0) }
        let primary = UUID()
        let row = try insert(remoteRow(split: true, primary: primary))
        let split = try XCTUnwrap(row.splitPaneIdentity)
        let splitOrigin = try XCTUnwrap(row.remotePresentation?.binding.remotePane(forLocal: split))
        let pool = pools.pool(for: "p4linux")
        let scratch = UUID()
        for shown in [true, false] {
            try store.applyRemoteLayout(PresentationLayout(panes: [primary, splitOrigin], primary: primary,
                                                           axis: SplitAxis.leftRight.rawValue, shown: true,
                                                           scratch: scratch, scratchShown: shown),
                                        forSession: row.id, attach: server)
        }
        let client = try XCTUnwrap(row.scratchClientIdentity)
        panes.append(client)
        XCTAssertFalse(row.scratchActive)
        XCTAssertNotNil(row.originScratch)
        server.tickReconnects()
        XCTAssertEqual(pool.load, [4])
        let oldLeft = try XCTUnwrap(row.initialCommand)

        XCTAssertTrue(try store.sleepRemoteRow(row.id, reason: .command))
        server.tickReconnects()

        XCTAssertEqual(pool.load, [2], "present: and the hidden scratch stay")

        XCTAssertTrue(try store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        XCTAssertEqual(pool.load, [4])
        let left = try XCTUnwrap(row.initialCommand)
        XCTAssertNotEqual(left, oldLeft)
        XCTAssertTrue(left.contains("ControlPath=\(path("p4linux", "pane:\(row.paneIdentity)"))"), left)
        XCTAssertTrue(left.contains(ZmxLeadBook.shared.states[row.paneIdentity]?.attachment.nonce ?? "missing"), left)
        XCTAssertTrue(row.splitInitialCommand?.contains(ZmxLeadBook.shared.states[split]?.attachment.nonce ?? "missing") == true)
        server.tickReconnects()
        XCTAssertEqual(pool.load, [4])
    }

    func testAnOriginScratchShownWhileAsleepAttachesOnlyAtTheWake() throws {
        library.onRowWake = { [weak server] in server?.wakeAttachLines(for: $0) }
        let primary = UUID()
        let row = try insert(remoteRow(primary: primary))
        let pool = pools.pool(for: "p4linux")
        XCTAssertTrue(try store.sleepRemoteRow(row.id, reason: .command))
        server.tickReconnects()
        let asleep = pool.load

        try store.applyRemoteLayout(PresentationLayout(panes: [primary], primary: primary, shown: false,
                                                       scratch: UUID(), scratchShown: true),
                                    forSession: row.id, attach: server)

        let client = try XCTUnwrap(row.scratchClientIdentity)
        panes.append(client)
        XCTAssertFalse(row.scratchActive)
        XCTAssertNil(row.scratchCommand)
        XCTAssertNil(ZmxLeadBook.shared.states[client])
        XCTAssertEqual(pool.load, asleep)

        XCTAssertTrue(try store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        XCTAssertTrue(row.scratchActive)
        let line = try XCTUnwrap(row.scratchCommand)
        XCTAssertTrue(line.contains("ControlPath=\(path("p4linux", "pane:\(client)"))"), line)
        XCTAssertTrue(line.contains(ZmxLeadBook.shared.states[client]?.attachment.nonce ?? "missing"), line)
    }

    func testARenewalWritesTheEndedLineForAPaneWhoseDaemonIsGone() throws {
        let row = try insert(remoteRow(split: true))
        let split = try XCTUnwrap(row.splitPaneIdentity)
        let binding = try XCTUnwrap(row.remotePresentation?.binding)
        let left = try XCTUnwrap(binding.daemon(forLocalPane: row.paneIdentity))
        row.remotePresentation?.binding = RemoteBinding(remoteSessionID: binding.remoteSessionID,
                                                        daemonsByLocalPane: [row.paneIdentity: left],
                                                        presentationVersion: binding.presentationVersion, origin: binding.origin)
        let splitLead = ZmxLeadBook.shared.states[split]?.attachment.nonce

        server.renewAttachLines(for: row)

        XCTAssertEqual(row.splitInitialCommand, RemoteSession.endedCommand(host: "p4linux"))
        XCTAssertEqual(ZmxLeadBook.shared.states[split]?.attachment.nonce, splitLead, "an ended pane begins no lead")
        XCTAssertTrue(row.initialCommand?.contains(ZmxLeadBook.shared.states[row.paneIdentity]?.attachment.nonce ?? "missing") == true)
    }

    func testARenewalLeavesALocalRowAlone() throws {
        let local = try XCTUnwrap(try store.addSession(toWorkspace: try XCTUnwrap(try store.currentWorkspaceID), cwd: "/tmp"))
        local.initialCommand = "make"

        server.renewAttachLines(for: local)

        XCTAssertEqual(local.initialCommand, "make")
        XCTAssertNil(local.splitInitialCommand)
    }

    func testALibraryGivenARegistryRestoresAnUpstreamPathRowOnItsPool() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let scratchDir = stateDir.appendingPathComponent("source", isDirectory: true)
        let source = AppStore(persistence: PersistenceStore(directory: scratchDir), paneFinalizer: nil)
        let workspace = source.addWorkspace(name: "work")
        let row = try XCTUnwrap(source.addSession(toWorkspace: workspace.id, cwd: "/a", remoteHost: "p4linux", remoteSessionID: "o1"))
        source.bindRemote(RemoteBinding(remoteSessionID: "o1", daemonsByLocalPane: [row.paneIdentity: ZmxSupport.daemonName(for: UUID())],
                                        presentationVersion: 1,
                                        origin: RemoteBinding.Origin(host: "p4linux", endpoint: Self.endpoint, sessionName: "o1")),
                          forSession: row.id)
        var snapshot = source.snapshot()
        let index = try XCTUnwrap(snapshot.workspaces.firstIndex { $0.id == workspace.id })
        snapshot.workspaces[index].attached = source.attachedSnapshots(of: source.workspaces[index], includingBookRows: true)
        snapshot.selectedSessionID = row.id
        try library.persistenceStore(for: windowID).save(snapshot)
        let restoredPools = SshHostPools(root: "/tmp/agterm-ssh-test", owner: stateDir.path + "-restored", runner: runner)

        let restored = WindowLibrary(directory: stateDir, paneFinalizer: nil, sshHostPools: restoredPools)

        let back = try XCTUnwrap(restored.store(for: windowID)?.session(withID: row.id))
        panes.append(back.paneIdentity)
        let line = try XCTUnwrap(back.initialCommand)
        XCTAssertTrue(line.contains("ControlPath=\(restoredPools.pool(for: "p4linux").lease("pane:\(back.paneIdentity)"))"), line)
        XCTAssertTrue(restored.store(for: windowID)?.sshHostPools === restoredPools)
    }

    private func surface(for row: Session) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": row.paneIdentity.uuidString], backedByZmx: false)
        view.session = row
        row.surface = view
        return view
    }
}
