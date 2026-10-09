import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRebasedOverlayTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!
    private var runtime: FakeRebasedRuntime!
    private var frames: FakeRebasedFrames!
    private var previousHost: RebasedHost!
    private var frameWindow: NSWindow!

    override func setUp() async throws {
        stateDir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agterm-rebased-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        server = ControlServer(library: library, actions: actions,
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                               identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                               socketPath: stateDir.appendingPathComponent("control.sock").path)
        runtime = FakeRebasedRuntime()
        frames = FakeRebasedFrames()
        frameWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        frameWindow.isReleasedWhenClosed = false
        frames.names[ObjectIdentifier(frameWindow)] = "frame"
        previousHost = RebasedHost.shared
        let host = RebasedHost()
        host.runtime = runtime
        host.frames = frames
        host.store = { [library] in library?.store(forSession: $0) }
        host.window = { [frameWindow] _ in frameWindow }
        host.after = { _, _ in }
        host.offMain = { work, done in
            work()
            done()
        }
        host.install()
        RebasedHost.shared = host
    }

    override func tearDown() async throws {
        RebasedHost.shared = previousHost
        RebasedOverlayReleases.shared.onRelease = nil
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: stateDir.path)))
    }

    private func openRebased(_ session: Session, sizePercent: Int? = nil) -> ControlResponse {
        server.openSessionOverlay(session.id.uuidString, window: nil,
                                  options: ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: sizePercent,
                                                                           backgroundColor: nil, rebased: true))
    }

    private func frameOpened(_ session: Session) {
        RebasedHost.shared.setSlotVisible(true, session: session.id)
        RebasedHost.shared.handle(event: "ready", payload: "")
        RebasedHost.shared.handle(event: "frameOpened", payload: "\(stateDir.path)\t7")
    }

    func testPaneSlotVisibilityFollowsCoversAsksAndHiddenState() throws {
        let (store, session) = try addSession()
        store.toggleSplit(session.id)
        let overlay = RebasedOverlay(project: "/repo", state: .shown)
        XCTAssertNil(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .left))
        func visible(_ shown: Bool = true, covered: Bool = false) -> Bool {
            RebasedSlot.isVisible(shown, session: session, pane: .left, overlaid: DeckPaneGates.coverActive(session), covered: covered)
        }
        XCTAssertTrue(visible())
        XCTAssertFalse(visible(false))
        XCTAssertFalse(visible(covered: true))
        XCTAssertTrue(store.openOverlay(session.id, command: "floating", sizePercent: 60))
        XCTAssertFalse(visible())
        store.closeOverlay(session.id)
        XCTAssertTrue(visible())
        session.scratchActive = true
        XCTAssertFalse(visible())
        session.scratchActive = false
        XCTAssertTrue(visible())
        session.overlayActive = true
        session.hudSpec = HudSpec(message: "notice")
        XCTAssertTrue(visible())
        store.closeHud(session.id)
        let ask = PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: [])
        XCTAssertTrue(session.openAsk(ask, paneIdentity: session.splitPaneIdentity))
        XCTAssertTrue(visible())
        session.cancelPendingAsk()
        XCTAssertTrue(session.openAsk(ask, paneIdentity: session.paneIdentity))
        XCTAssertFalse(visible())
        session.cancelPendingAsk()
        XCTAssertTrue(session.openAsk(ask))
        XCTAssertFalse(visible())
        session.cancelPendingAsk()
        XCTAssertTrue(store.setRebasedHidden(session.id, id: overlay.id, true))
        XCTAssertFalse(visible())
        XCTAssertTrue(store.setRebasedHidden(session.id, id: overlay.id, false))
        XCTAssertTrue(visible())
    }

    func testShownElsewhereMessageNeedsAnotherHolderAndLocalVisibility() {
        var overlay = RebasedOverlay(project: "/repo", state: .shown)
        XCTAssertEqual(RebasedSlot.message(for: overlay, shownElsewhere: true), "Rebased is shown in another session")
        XCTAssertNil(RebasedSlot.message(for: overlay, shownElsewhere: false))
        XCTAssertNil(RebasedSlot.message(for: overlay, shownElsewhere: true, visible: false))
        overlay.hidden = true
        XCTAssertNil(RebasedSlot.message(for: overlay, shownElsewhere: true))
    }

    func testOpenRoutesToTheHostAndShowsInTheTree() throws {
        let (store, session) = try addSession()
        let response = openRebased(session, sizePercent: 70)
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(runtime.starts, 1)
        frameOpened(session)
        let node = try XCTUnwrap(server.buildTree(in: store).workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        XCTAssertEqual(node.rebasedOverlay, ControlRebasedOverlayNode(project: stateDir.path, state: "shown", hidden: false))
        XCTAssertEqual(node.overlaySizePercent, 70)
        XCTAssertEqual(server.buildTree(in: store).rebased?.jvm, "running")
    }

    func testADiffReachesTheBridgeAndTheTree() throws {
        let (store, session) = try addSession()
        let diff = RebasedDiff(base: "main", head: "topic", mergeBase: false)
        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                                                          backgroundColor: nil, rebased: true, rebasedDiff: diff))
        XCTAssertTrue(response.ok, response.error ?? "")
        frameOpened(session)
        XCTAssertEqual(runtime.calls.last, "diff main\ttopic\t0\t\(RebasedHost.canonical(stateDir.path))")
        let node = try XCTUnwrap(server.buildTree(in: store).workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        XCTAssertEqual(node.rebasedOverlay?.diff, "main..topic")
    }

    func testCloseHidesTheFrame() throws {
        let (_, session) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        frameOpened(session)
        XCTAssertTrue(server.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).ok)
        XCTAssertNil(session.rebasedOverlay)
        XCTAssertEqual(runtime.calls.last, "hide \(RebasedHost.canonical(stateDir.path))")
    }

    func testResizeChangesTheSharedOverlaySize() throws {
        let (_, session) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        XCTAssertTrue(server.resizeSessionOverlay(session.id.uuidString, window: nil, sizePercent: 55).ok)
        XCTAssertEqual(session.overlaySizePercent, 55)
    }

    func testToggleOpensClosesAndRefusesOverAProgram() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        actions.toggleRebasedOverlay()
        XCTAssertTrue(session.rebasedOverlayActive)
        actions.toggleRebasedOverlay()
        XCTAssertFalse(session.overlayActive)
        XCTAssertTrue(store.openOverlay(session.id, command: "htop"))
        actions.toggleRebasedOverlay()
        XCTAssertNil(session.rebasedOverlay)
        XCTAssertTrue(session.programOverlayActive)
        store.closeOverlay(session.id)
    }

    func testAHiddenSlotHidesTheFrameAndShowsItAgain() throws {
        let (_, session) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        frameOpened(session)
        let project = RebasedHost.canonical(stateDir.path)
        RebasedHost.shared.setSlotVisible(false, session: session.id)
        XCTAssertEqual(runtime.calls.last, "hide \(project)")
        XCTAssertFalse(RebasedHost.shared.isShown(in: session.id))
        RebasedHost.shared.setSlotVisible(true, session: session.id)
        XCTAssertEqual(runtime.calls.last, "show \(project)")
        XCTAssertTrue(RebasedHost.shared.isShown(in: session.id))
    }

    func testAFrameArrivingWhileTheSlotIsHiddenWaitsForIt() throws {
        let (_, session) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        RebasedHost.shared.handle(event: "ready", payload: "")
        RebasedHost.shared.handle(event: "frameOpened", payload: "\(stateDir.path)\t7")
        XCTAssertEqual(session.rebasedOverlay?.state, .shown)
        XCTAssertFalse(RebasedHost.shared.isShown(in: session.id))
        RebasedHost.shared.setSlotVisible(true, session: session.id)
        XCTAssertTrue(RebasedHost.shared.isShown(in: session.id))
    }

    func testQuitSavesOnlyWhenTheJVMRuns() throws {
        RebasedHost.shared.saveBeforeQuit()
        XCTAssertTrue(runtime.calls.isEmpty)
        let (_, session) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        frameOpened(session)
        RebasedHost.shared.saveBeforeQuit()
        XCTAssertEqual(runtime.calls.last, "saveAll ")
    }

    func testToggleForAGivenSessionClosesThatSessionsOverlay() throws {
        let (store, session) = try addSession()
        let (_, other) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        store.selectSession(other.id)
        actions.toggleRebasedOverlay(session: session.id)
        XCTAssertNil(session.rebasedOverlay)
        XCTAssertFalse(other.overlayActive)
    }
}
