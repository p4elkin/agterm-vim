import SwiftUI
import XCTest
@testable import agterm
@testable import agtermCore

@MainActor
final class ControlServerRemoteSleepTests: XCTestCase {
    private var directory: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var store: AppStore!
    private var windowID: UUID!
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var hiddenWindows: Set<UUID> = []
    private var panes: [UUID] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-sleep-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        server = ControlServer(library: library, actions: AppActions(library: library),
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: directory)),
                               identity: AppIdentity(version: "9.9.9"),
                               socketPath: "/tmp/agterm-sl-\(UUID().uuidString.prefix(8)).sock")
        server.hudClock = { [unowned self] in now }
        server.windowOnScreen = { [unowned self] in !hiddenWindows.contains($0) }
        library.onRowWake = { [weak server] in server?.wakeAttachLines(for: $0) }
        store = try XCTUnwrap(library.activeStore)
        windowID = try XCTUnwrap(library.activeWindowID)
    }

    override func tearDown() async throws {
        WindowRegistry.shared.unregister(windowID)
        TerminalZoomRegistry.shared.unregister(windowID)
        DashboardControllerRegistry.shared.unregister(windowID)
        panes.forEach { ZmxLeadBook.shared.forget(pane: $0) }
        server.stop()
        server = nil
        store = nil
        library = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func remoteRow(select: Bool = false, split: Bool = false) throws -> Session {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let row = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp", select: select, remoteHost: "box"))
        var daemons = [row.paneIdentity: ZmxSupport.daemonName(for: UUID())]
        if split {
            store.toggleSplit(row.id)
            daemons[try XCTUnwrap(row.splitPaneIdentity)] = ZmxSupport.daemonName(for: UUID())
        }
        store.bindRemote(RemoteBinding(remoteSessionID: "s-\(UUID().uuidString)", daemonsByLocalPane: daemons,
                                       presentationVersion: 1,
                                       origin: .init(host: "box", endpoint: ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/zmx"),
                                                     sessionName: "build")),
                         forSession: row.id)
        panes += daemons.keys
        return row
    }

    private func zoom() -> TerminalZoomController {
        let controller = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: controller)
        return controller
    }

    private func dashboard() -> DashboardController {
        let controller = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: controller)
        return controller
    }

    private func tick(after seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        server.tickReconnects()
    }

    func testSelectingAnAsleepRowWakesIt() throws {
        let row = try remoteRow()
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer))

        store.selectSession(row.id)

        XCTAssertFalse(row.asleep)
        XCTAssertNotNil(row.initialCommand)
    }

    func testOpeningTheDashboardWakesItsAsleepMembersBeforeAnyTileMounts() throws {
        let control = try remoteRow()
        let gui = try remoteRow()
        let grid = dashboard()
        store.selectSession(gui.id)
        store.selectSession(try XCTUnwrap(store.workspaces.first?.sessions.first?.id))
        XCTAssertTrue(store.sleepRemoteRow(control.id, reason: .timer))
        XCTAssertTrue(store.sleepRemoteRow(gui.id, reason: .timer))

        XCTAssertTrue(server.setDashboard(targets: [control.id.uuidString], window: nil, close: false,
                                          fontMode: .untouched, mru: false).ok)
        XCTAssertFalse(control.asleep)
        grid.close()

        AppActions(library: library).toggleDashboard()
        XCTAssertTrue(grid.members.contains { $0.session == gui.id })
        XCTAssertFalse(gui.asleep)
    }

    func testZoomingAnAsleepRowWakesItFirst() throws {
        let control = try remoteRow()
        let lens = zoom()
        XCTAssertTrue(store.sleepRemoteRow(control.id, reason: .timer))

        XCTAssertTrue(server.setSurfaceZoom("surface:\(control.id.uuidString):left", window: nil, mode: .on).ok)

        XCTAssertEqual(lens.target, .session(control.id, .primary))
        XCTAssertFalse(control.asleep)
    }

    func testZoomingTheActiveAsleepRowWakesItFirstFromControlAndFromTheGUI() throws {
        let selected = try remoteRow(select: true)
        let lens = zoom()
        lens.targetResolver = { [store] in store.flatMap { TerminalZoomController.resolveTarget(store: $0) } }
        XCTAssertTrue(store.sleepRemoteRow(selected.id, reason: .command))

        XCTAssertTrue(server.setSurfaceZoom("active", window: nil, mode: .on).ok)
        XCTAssertFalse(selected.asleep)

        lens.clear()
        XCTAssertTrue(store.sleepRemoteRow(selected.id, reason: .command))
        AppActions(library: library).toggleTerminalZoom()
        XCTAssertEqual(lens.target, .session(selected.id, .primary))
        XCTAssertFalse(selected.asleep)
    }

    func testADashboardReconcileWakesAnAsleepMember() throws {
        let first = try remoteRow()
        let second = try remoteRow()
        let content = WindowContentView(
            windowID: windowID, store: store, library: library,
            makeSurface: { _ in GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()) },
            makeSplitSurface: { _ in GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()) },
            makeOverlaySurface: { _, _ in GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()) },
            makeScratchSurface: { _ in GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()) },
            captureOnExit: nil, actions: AppActions(library: library), palette: PaletteController(),
            sessionSwitcher: SessionSwitcher(library: library, canSwitch: { false }),
            toolbarMode: .normal, chromeText: .white, attentionButtonEnabled: false, hiddenInterfaceElements: [])
        content.dashboard.open(members: [DashboardMember(session: first.id, surface: .primary),
                                         DashboardMember(session: second.id, surface: .primary)])
        XCTAssertTrue(store.sleepRemoteRow(first.id, reason: .command))

        content.reconcileDashboardMembers()

        XCTAssertTrue(content.dashboard.members.contains { $0.session == first.id })
        XCTAssertFalse(first.asleep)
    }

    func testAWindowOpeningWakesItsAsleepSelectedRowBeforeAnyTick() throws {
        let selected = try remoteRow(select: true)
        XCTAssertTrue(store.sleepRemoteRow(selected.id, reason: .command))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        WindowRegistry.shared.register(windowID, window: window)

        XCTAssertFalse(selected.asleep)
    }

    func testARegisteredWindowWakesItsAsleepSelectedRowWhenItBecomesVisible() throws {
        server.windowOnScreen = ControlServer.windowIsOnScreen
        let selected = try remoteRow(select: true)
        XCTAssertTrue(store.sleepRemoteRow(selected.id, reason: .command))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.orderOut(nil) }

        WindowRegistry.shared.register(windowID, window: window)
        XCTAssertTrue(selected.asleep, "registered before it is visible")

        window.orderFront(nil)

        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(selected.asleep)
    }

    func testTheTickSleepsAnUnselectedRowAfterTheSettingAndLeavesTheShownOnes() throws {
        let hidden = try remoteRow()
        let selected = try remoteRow(select: true)
        let zoomed = try remoteRow()
        let member = try remoteRow()
        zoom().set(.on, target: .session(zoomed.id, .primary))
        dashboard().open(members: [DashboardMember(session: member.id, surface: .primary)])

        tick(after: 0)
        XCTAssertEqual(hidden.offScreenSince, now)
        tick(after: 29 * 60)
        XCTAssertFalse(hidden.asleep)
        tick(after: 60)

        XCTAssertTrue(hidden.asleep)
        XCTAssertFalse(selected.asleep)
        XCTAssertFalse(zoomed.asleep)
        XCTAssertFalse(member.asleep)
        XCTAssertNil(selected.offScreenSince)
    }

    func testAMinimizedWindowsSelectedRowSleepsAndWakesWhenTheWindowOrTheAppIsShownAgain() throws {
        let selected = try remoteRow(select: true)
        hiddenWindows = [windowID]

        tick(after: 0)
        tick(after: 30 * 60)
        XCTAssertTrue(selected.asleep)

        hiddenWindows = []
        server.windowBecameVisible(windowID)
        XCTAssertFalse(selected.asleep)

        hiddenWindows = [windowID]
        tick(after: 0)
        tick(after: 30 * 60)
        XCTAssertTrue(selected.asleep)
        hiddenWindows = []
        server.appBecameVisible()
        XCTAssertFalse(selected.asleep)
    }

    func testAZoomTargetAndADashboardMemberInAMinimizedWindowNeverSleep() throws {
        let zoomed = try remoteRow()
        let member = try remoteRow()
        let selected = try remoteRow(select: true)
        zoom().set(.on, target: .session(zoomed.id, .primary))
        dashboard().open(members: [DashboardMember(session: member.id, surface: .primary)])
        hiddenWindows = [windowID]

        tick(after: 0)
        tick(after: 60 * 60)

        XCTAssertTrue(selected.asleep, "the policy ran")
        XCTAssertFalse(zoomed.asleep)
        XCTAssertFalse(member.asleep)
    }

    func testAWakeByCommandThenATickLeavesTheRowAwake() throws {
        let row = try remoteRow()
        let longHidden = try remoteRow()
        longHidden.offScreenSince = now.addingTimeInterval(-31 * 60)
        row.offScreenSince = now.addingTimeInterval(-31 * 60)
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .command))
        let wokeAt = now
        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .command, onScreen: false, now: wokeAt))

        tick(after: 60)

        XCTAssertTrue(longHidden.asleep, "the policy ran")
        XCTAssertFalse(row.asleep)
        XCTAssertEqual(row.offScreenSince, wokeAt, "the wake restarted the clock")
    }

    func testTheNextTickWakesAnAsleepSelectedRowInAVisibleWindow() throws {
        let selected = try remoteRow(select: true)
        XCTAssertTrue(store.sleepRemoteRow(selected.id, reason: .command))

        tick(after: 1)

        XCTAssertFalse(selected.asleep)
    }

    func testTheSixtySecondLimitLivesInThePolicyRunItself() throws {
        let row = try remoteRow()
        tick(after: 0)
        row.offScreenSince = now.addingTimeInterval(-31 * 60)

        now = now.addingTimeInterval(10)
        server.retryRemoteLinksNow()
        XCTAssertFalse(row.asleep, "an extra tick inside the minute does not run the policy")

        tick(after: 50)
        XCTAssertTrue(row.asleep)
    }

    func testARowThatEndedOnItsHostWhileAsleepWakesIntoTheEndedLine() throws {
        let row = try remoteRow(split: true)
        let split = try XCTUnwrap(row.splitPaneIdentity)
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer))
        store.setRemoteRowState(.endedOnHost, forSession: row.id)

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        let ended = RemoteSession.endedCommand(host: "box")
        XCTAssertEqual(row.initialCommand, ended)
        XCTAssertEqual(row.splitInitialCommand, ended)
        XCTAssertNil(ZmxLeadBook.shared.states[row.paneIdentity], "an ended pane begins no lead")
        XCTAssertNil(ZmxLeadBook.shared.states[split])
    }

    func testARowThatEndedOnItsHostWhileAsleepAttachesNoScratchOnWake() throws {
        let row = try remoteRow()
        let primary = try XCTUnwrap(row.remotePresentation?.binding.remotePane(forLocal: row.paneIdentity))
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer))
        _ = store.applyRemoteLayout(PresentationLayout(panes: [primary], primary: primary, shown: false,
                                                       scratch: UUID(), scratchShown: true),
                                    forSession: row.id, attach: server)
        XCTAssertNil(row.scratchCommand)
        store.setRemoteRowState(.endedOnHost, forSession: row.id)

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        XCTAssertNil(row.scratchCommand)
        XCTAssertFalse(row.scratchActive)
    }

    func testAWakeBuildsTheUnshownPrimaryOfAHiddenSplitFocusedRight() throws {
        let row = try remoteRow(split: true)
        store.setSplitVisibility(row.id, shown: false)
        row.splitFocused = true
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer))
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library),
                                                 zmxForegroundResolver: nil, spawnRegistry: SpawnRegistry(pacer: SpawnPacer()),
                                                 launchContext: agtermApp.LaunchSpawnContext())
        library.onRowWake = agtermApp.wakeRenewal(server: server, services: services, env: { _, _ in [:] })
        server.userPresent = { true }

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        let primary = try XCTUnwrap(row.surface as? GhosttySurfaceView, "the primary is built though the deck shows only the right pane")
        addTeardownBlock { primary.teardown() }
        XCTAssertTrue(primary.isRealized)
        let nonce = try XCTUnwrap(ZmxLeadBook.shared.states[row.paneIdentity]?.attachment.nonce)
        let notice = try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;\(nonce):leader:1"))
        _ = ZmxLeadBook.shared.apply(notice, pane: row.paneIdentity)
        XCTAssertTrue(server.leadsHere(row.id))
    }

    func testAWakeBuildsTheUnshownRightPaneOfAHiddenSplitFocusedLeftThatASleepReleased() throws {
        let row = try remoteRow(split: true)
        let split = try XCTUnwrap(row.splitPaneIdentity)
        store.setSplitVisibility(row.id, shown: false)
        row.splitFocused = false
        row.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer))
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library),
                                                 zmxForegroundResolver: nil, spawnRegistry: SpawnRegistry(pacer: SpawnPacer()),
                                                 launchContext: agtermApp.LaunchSpawnContext())
        library.onRowWake = agtermApp.wakeRenewal(server: server, services: services, env: { _, _ in [:] })

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .pty, onScreen: false))

        let right = try XCTUnwrap(row.splitSurface as? GhosttySurfaceView, "a --pane right command waits on this pane")
        addTeardownBlock { right.teardown() }
        XCTAssertTrue(right.isRealized)
        XCTAssertNil(row.surface, "the deck builds the shown primary")
        XCTAssertNotNil(ZmxLeadBook.shared.states[split])
    }

    func testAWakeBuildsNoRightPaneThatNeverExisted() throws {
        let row = try remoteRow(split: true)
        store.setSplitVisibility(row.id, shown: false)
        row.splitFocused = false
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer))
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library),
                                                 zmxForegroundResolver: nil, spawnRegistry: SpawnRegistry(pacer: SpawnPacer()),
                                                 launchContext: agtermApp.LaunchSpawnContext())
        library.onRowWake = agtermApp.wakeRenewal(server: server, services: services, env: { _, _ in [:] })

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        XCTAssertNil(row.splitSurface)
    }

    func testTheDeckBuildsOnlyTheRightPaneBesideTheOffDeckPrimary() throws {
        let (row, made) = try deckAfterWakingAHiddenSplit(focusedRight: true)

        XCTAssertEqual(made, ["right"], "the deck reuses the primary the wake built")
        XCTAssertFalse(row.splitSurface === row.surface)
    }

    func testTheDeckBuildsOnlyThePrimaryBesideTheOffDeckRightPane() throws {
        let (row, made) = try deckAfterWakingAHiddenSplit(focusedRight: false)

        XCTAssertEqual(made, ["left"], "the deck reuses the right pane the wake built")
        XCTAssertFalse(row.splitSurface === row.surface)
    }

    /// deckAfterWakingAHiddenSplit mounts the deck over an asleep row whose split is hidden, wakes it, and answers the
    /// panes the deck built; both slots then hold a realized surface.
    private func deckAfterWakingAHiddenSplit(focusedRight: Bool) throws -> (Session, [String]) {
        let row = try remoteRow(split: true)
        store.setSplitVisibility(row.id, shown: false)
        row.splitFocused = focusedRight
        _ = store.selectSession(nil)
        row.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer))
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library),
                                                 zmxForegroundResolver: nil, spawnRegistry: SpawnRegistry(pacer: SpawnPacer()),
                                                 launchContext: agtermApp.LaunchSpawnContext())
        library.onRowWake = agtermApp.wakeRenewal(server: server, services: services, env: { _, _ in [:] })
        var made: [(pane: String, view: GhosttySurfaceView)] = []
        func stub(_ pane: String, _ session: Session) -> GhosttySurfaceView {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            if session.id == row.id { made.append((pane, view)) }
            return view
        }
        let content = WindowContentView(
            windowID: windowID, store: store, library: library,
            makeSurface: { stub("left", $0) }, makeSplitSurface: { stub("right", $0) },
            makeOverlaySurface: { session, _ in stub("overlay", session) }, makeScratchSurface: { stub("scratch", $0) },
            captureOnExit: nil, actions: AppActions(library: library), palette: PaletteController(),
            sessionSwitcher: SessionSwitcher(library: library, canSwitch: { false }),
            toolbarMode: .normal, chromeText: .white, attentionButtonEnabled: false, hiddenInterfaceElements: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            made.forEach { $0.view.teardown() }
            (row.surface as? GhosttySurfaceView)?.teardown()
            (row.splitSurface as? GhosttySurfaceView)?.teardown()
            window.close()
        }
        window.contentView = NSHostingView(rootView: content.detailPane.frame(width: 800, height: 500))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(made.isEmpty, "an asleep row builds no pane")

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        let shown = focusedRight ? "right" : "left"
        let deadline = Date().addingTimeInterval(5)
        while !made.contains(where: { $0.pane == shown }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let offDeck = focusedRight ? row.surface : row.splitSurface
        XCTAssertTrue((offDeck as? GhosttySurfaceView)?.isRealized == true, "the wake built the unshown pane")
        XCTAssertNotNil(focusedRight ? row.splitSurface : row.surface)
        return (row, made.map(\.pane))
    }
}
