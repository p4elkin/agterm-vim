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
        host.isFocusedPane = { [library] id, pane in
            guard let store = library?.activeStore else { return false }
            return store.selectedSessionID == id && store.session(withID: id)?.focusedPane == pane
        }
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

    func testPaneOpenWithOnClose() throws {
        let (store, session) = try addSession()
        store.toggleSplit(session.id)
        let view = RebasedView.diff(RebasedDiff(base: "A", head: "HEAD", mergeBase: false), workingTree: true)
        var commands: [RebasedOnClose] = []
        RebasedHost.shared.runOnClose = { commands.append($0) }
        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
            options: ControlSessionOverlayOpenOptions(command: "", cwd: stateDir.path, wait: false, sizePercent: nil,
                backgroundColor: nil, pane: .left, rebased: true, rebasedView: view, rebasedOnClose: "/bin/flush"))
        XCTAssertTrue(response.ok, response.error ?? "")
        let overlay = try XCTUnwrap(response.result?.overlay)
        let request = try XCTUnwrap(response.result?.request)
        XCTAssertEqual(response.result?.id, session.id.uuidString)
        XCTAssertEqual(session.leftOverlay?.rebased?.id.uuidString, overlay)
        frameOpened(session)
        let node = try XCTUnwrap(server.buildTree(in: store).workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }?.rebasedOverlay)
        XCTAssertEqual(node.pane, "left")
        XCTAssertEqual(node.hidden, false)
        XCTAssertEqual(node.onClose, true)
        XCTAssertEqual(node.view?.request, request)
        XCTAssertEqual(node.view?.kind, "working-tree")
        RebasedHost.shared.handle(event: "viewOpened", payload: request + "\t2")
        XCTAssertEqual(session.leftOverlay?.rebased?.view?.state, .opened)
        let stale = server.closeSessionOverlay(session.id.uuidString, window: nil, overlay: UUID())
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(session.leftOverlay?.rebased?.id.uuidString, overlay)
        XCTAssertTrue(commands.isEmpty)
        let closed = server.closeSessionOverlay(session.id.uuidString, window: nil, overlay: try XCTUnwrap(UUID(uuidString: overlay)))
        XCTAssertTrue(closed.ok, closed.error ?? "")
        XCTAssertEqual(commands.map(\.command), ["/bin/flush"])
        XCTAssertNil(session.leftOverlay)
    }

    func testProjectFileShowAndCloseUseTheHeldOverlayID() throws {
        let (store, session) = try addSession()
        store.toggleSplit(session.id)
        let project = stateDir.appendingPathComponent("repo/sub")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
            options: ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                pane: .left, rebased: true, rebasedView: .file(path: project.appendingPathComponent("a.kt").path, line: 3), rebasedProject: project.path))
        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(session.leftOverlay?.rebased?.project, project.path)
        let firstRequest = try XCTUnwrap(response.result?.request)
        RebasedHost.shared.setSlotVisible(true, session: session.id)
        RebasedHost.shared.handle(event: "ready", payload: "")
        RebasedHost.shared.handle(event: "frameOpened", payload: "\(project.path)\t7")
        XCTAssertEqual(runtime.calls.last, "openFile \(firstRequest)\t3\t\(project.appendingPathComponent("a.kt").path)\t\(RebasedHost.canonical(project.path))")
        let shown = server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: project.appendingPathComponent("b.kt").path, line: 9))
        XCTAssertTrue(shown.ok, shown.error ?? "")
        XCTAssertNotEqual(shown.result?.request, firstRequest)
        XCTAssertEqual(shown.result?.overlay, response.result?.overlay)
        let refused = server.openSessionOverlay(session.id.uuidString, window: nil,
            options: ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                     pane: .right, rebased: true, rebasedProject: project.path))
        XCTAssertFalse(refused.ok)
        let id = try XCTUnwrap(session.rebasedPlacement?.overlay.id)
        XCTAssertTrue(server.closeSessionOverlay(session.id.uuidString, window: nil, overlay: id).ok)
        XCTAssertEqual(server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: "/a", line: 0)).error,
                       "no Rebased overlay in this session")
        XCTAssertTrue(store.openOverlay(session.id, command: "reader"))
        XCTAssertFalse(server.closeSessionOverlay(session.id.uuidString, window: nil, overlay: id).ok)
        XCTAssertTrue(session.programOverlayActive)
    }

    func testControlToggleOpensHidesAndShowsWithReadback() throws {
        let (store, session) = try addSession()
        let opened = server.toggleRebasedOverlay(session.id.uuidString, window: nil)
        XCTAssertTrue(opened.ok)
        XCTAssertEqual(opened.result?.text, "opened")
        let id = try XCTUnwrap(opened.result?.overlay)
        frameOpened(session)
        let hidden = server.toggleRebasedOverlay(session.id.uuidString, window: nil)
        XCTAssertEqual(hidden.result?.text, "hidden")
        XCTAssertEqual(hidden.result?.overlay, id)
        XCTAssertEqual(session.rebasedOverlay?.hidden, true)
        let queued = server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: "/a", line: 0))
        XCTAssertTrue(queued.ok)
        XCTAssertEqual(session.rebasedOverlay?.view?.state, .queued)
        let shown = server.toggleRebasedOverlay(session.id.uuidString, window: nil)
        XCTAssertEqual(shown.result?.text, "shown")
        XCTAssertEqual(shown.result?.overlay, id)
        XCTAssertEqual(session.rebasedOverlay?.view?.state, .sent)
        store.closeOverlay(session.id)
        XCTAssertTrue(store.openOverlay(session.id, command: "reader"))
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).error, "overlay already open")
    }

    func testRemoteRowsRefuseLocalFlagsButStillOpenAndShowDiffs() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/repo", remoteHost: "remote"))
        let diff = RebasedDiff(base: "A", head: "HEAD", mergeBase: false)
        let options: [(String, ControlSessionOverlayOpenOptions)] = [
            ("working-tree", .init(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true, rebasedView: .diff(diff, workingTree: true))),
            ("file", .init(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true, rebasedView: .file(path: "/repo/a", line: 0))),
            ("project", .init(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true, rebasedProject: "/repo")),
            ("on-close", .init(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true, rebasedOnClose: "/bin/flush"))
        ]
        for (flag, options) in options {
            XCTAssertEqual(server.openSessionOverlay(session.id.uuidString, window: nil, options: options).error,
                           "--\(flag) works on a local row only")
            XCTAssertNil(session.rebasedPlacement)
        }
        let directory = stateDir.path
        RebasedHost.shared.mirrorRefresh = { _, _ in .success(.init(directory: directory, source: "remote:/repo")) }
        let opened = server.openSessionOverlay(session.id.uuidString, window: nil,
            options: .init(command: "", cwd: "/repo", wait: false, sizePercent: nil, backgroundColor: nil, rebased: true,
                           rebasedView: .diff(diff, workingTree: false)))
        XCTAssertTrue(opened.ok, opened.error ?? "")
        frameOpened(session)
        XCTAssertEqual(server.showRebasedView(session.id.uuidString, window: nil, view: .diff(diff, workingTree: true)).error,
                       "--working-tree works on a local row only")
        XCTAssertEqual(server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: "/repo/a", line: 0)).error,
                       "--file works on a local row only")
        let shown = server.showRebasedView(session.id.uuidString, window: nil, view: .diff(diff, workingTree: false))
        XCTAssertTrue(shown.ok, shown.error ?? "")
        XCTAssertNotEqual(shown.result?.request, opened.result?.request)
    }

    func testPaneIDEHasNoProgramResultOrFontAndLeavesItsSiblingAddressable() throws {
        let (store, session) = try addSession()
        store.toggleSplit(session.id)
        let right = GhosttySurfaceView(workingDirectory: stateDir.path)
        session.splitSurface = right
        defer { right.teardown() }
        XCTAssertNil(store.openRebasedOverlay(session.id, overlay: RebasedOverlay(project: "/repo"), sizePercent: nil, pane: .left))
        XCTAssertEqual(server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left).error, OverlayResultError.noResult)
        XCTAssertEqual(server.font(session.id.uuidString, window: nil, pane: .left, action: "increase_font_size:1").error,
                       "Rebased overlay has no terminal font size")
        XCTAssertEqual(server.font(session.id.uuidString, window: nil, pane: .right, action: "increase_font_size:1").error,
                       "session not realized")
    }

    func testTheControlTreeIncludesTheKnownBuiltInPort() throws {
        let (store, session) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        frameOpened(session)
        RebasedHost.shared.idePort = 63342
        XCTAssertEqual(server.buildTree(in: store).rebased?.port, 63342)
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
        let request = try XCTUnwrap(session.rebasedOverlay?.view?.id)
        XCTAssertEqual(runtime.calls.last, "diff \(request)\tmain\ttopic\t0\t0\tsession\t\(RebasedHost.canonical(stateDir.path))")
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

    func testToggleHidesAndShowsTheSameHolder() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        XCTAssertEqual(actions.toggleRebasedOverlay(), .opened)
        let id = try XCTUnwrap(session.rebasedPlacement?.overlay.id)
        frameOpened(session)
        XCTAssertEqual(actions.toggleRebasedOverlay(), .hidden)
        XCTAssertTrue(session.overlayActive)
        XCTAssertEqual(session.rebasedPlacement?.overlay.id, id)
        XCTAssertEqual(server.buildTree(in: store).workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }?.rebasedOverlay?.hidden, true)
        XCTAssertEqual(runtime.calls.last, "hide \(RebasedHost.canonical(stateDir.path))")
        XCTAssertEqual(actions.toggleRebasedOverlay(), .shown)
        XCTAssertEqual(session.rebasedPlacement?.overlay.id, id)
        XCTAssertEqual(runtime.calls.last, "show \(RebasedHost.canonical(stateDir.path))")
        XCTAssertTrue(store.closeRebasedOverlay(session.id, id: id))
        XCTAssertTrue(store.openOverlay(session.id, command: "htop"))
        XCTAssertEqual(actions.toggleRebasedOverlay(), .refused("overlay already open"))
        XCTAssertTrue(session.programOverlayActive)
    }

    private final class FocusSurface: TerminalSurface {
        let isRealized = true
        let paneToken = UUID().uuidString
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    func testPaneToggleRefocusesTheUncoveredTerminalAndKeepsTheHolder() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        store.toggleSplit(session.id)
        session.splitFocused = false
        let surface = FocusSurface()
        session.surface = surface
        let opened = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path,
                                                       sizePercent: nil, pane: .left).get()
        frameOpened(session)
        var refocused = false
        actions.rebasedRefocus = { current in refocused = current.topmostSurface === surface }
        XCTAssertEqual(actions.toggleRebasedOverlay(), .hidden)
        XCTAssertTrue(refocused)
        XCTAssertEqual(session.leftOverlay?.rebased?.id, opened.overlay)
        XCTAssertEqual(actions.toggleRebasedOverlay(), .shown)
        XCTAssertEqual(session.leftOverlay?.rebased?.id, opened.overlay)
    }

    func testCommandWOverAReviewAlwaysConfirms() throws {
        let originalRelease = RebasedOverlayReleases.shared.onRelease
        defer { RebasedOverlayReleases.shared.onRelease = originalRelease }
        for scenario in ["left", "right", "hiddenPane", "hiddenSession", "shownSession"] {
            let (store, session) = try addSession()
            store.selectSession(session.id)
            let pane: OverlayPane? = scenario.hasSuffix("Session") ? nil : .left
            if pane != nil { store.toggleSplit(session.id) }
            session.splitFocused = scenario == "right"
            var commands: [RebasedOnClose] = []
            RebasedHost.shared.runOnClose = { commands.append($0) }
            let opened = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path,
                                                           sizePercent: nil, pane: pane, onClose: "/bin/flush --final").get()
            frameOpened(session)
            if scenario.hasPrefix("hidden") { XCTAssertEqual(actions.toggleRebasedOverlay(), .hidden) }
            var releases: [UUID] = []
            RebasedOverlayReleases.shared.onRelease = { id in releases.append(id); originalRelease?(id) }
            var messages: [String] = []
            var accepted = false
            actions.closeConfirmer = { message, detail in messages.append(message + " " + detail); return accepted }
            XCTAssertTrue(actions.closeActiveSession())
            XCTAssertEqual(messages.count, 1)
            XCTAssertTrue(messages[0].contains(stateDir.path))
            XCTAssertTrue(store.workspaces.flatMap(\.sessions).contains { $0.id == session.id })
            XCTAssertEqual(session.rebasedPlacement?.overlay.id, opened.overlay)
            XCTAssertTrue(releases.isEmpty)
            XCTAssertTrue(commands.isEmpty)
            accepted = true
            XCTAssertTrue(actions.closeActiveSession())
            XCTAssertEqual(messages.count, 2)
            if scenario == "shownSession" {
                XCTAssertTrue(store.workspaces.flatMap(\.sessions).contains { $0.id == session.id })
                XCTAssertNil(session.rebasedOverlay)
                XCTAssertFalse(store.undoPendingClose())
                XCTAssertEqual(releases, [opened.overlay])
                XCTAssertEqual(commands.map(\.command), ["/bin/flush --final"])
            } else {
                XCTAssertFalse(store.workspaces.flatMap(\.sessions).contains { $0.id == session.id })
                XCTAssertTrue(releases.isEmpty)
                store.finalizeAllPendingCloses()
                XCTAssertEqual(releases, [opened.overlay])
                XCTAssertEqual(commands.map(\.command), ["/bin/flush --final"])
            }
        }
    }

    func testCommandWWithoutAReviewKeepsTheDefaultNoDialogBehavior() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        var confirmations = 0
        actions.closeConfirmer = { _, _ in confirmations += 1; return false }
        XCTAssertTrue(actions.closeActiveSession())
        XCTAssertEqual(confirmations, 0)
        XCTAssertFalse(store.workspaces.flatMap(\.sessions).contains { $0.id == session.id })
        store.finalizeAllPendingCloses()
    }

    func testFocusingAPaneIDEMakesItKey() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        store.toggleSplit(session.id)
        session.splitFocused = false
        let surface = FocusSurface()
        session.surface = surface
        let opened = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path,
                                                       sizePercent: nil, pane: .left).get()
        frameOpened(session)
        let before = frames.log.filter { $0 == "makeKey frame" }.count
        actions.focusSplitPane(session, wantSplit: false)
        XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, before + 1)
        XCTAssertTrue(store.setRebasedHidden(session.id, id: opened.overlay, true))
        actions.focusSplitPane(session, wantSplit: false)
        XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, before + 1)
        XCTAssertTrue(session.focusTarget(wantSplit: false) === surface)
    }

    func testAnOpenOverTheFocusedPaneMakesTheIDEKeyOnce() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        store.toggleSplit(session.id)
        for rightFocused in [false, true] {
            session.splitFocused = false
            let opened = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path,
                                                           sizePercent: nil, pane: .left).get()
            session.splitFocused = rightFocused
            let before = frames.log.filter { $0 == "makeKey frame" }.count
            frameOpened(session)
            let expected = before + (rightFocused ? 0 : 1)
            XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, expected)
            RebasedHost.shared.setSlotVisible(false, session: session.id)
            RebasedHost.shared.setSlotVisible(true, session: session.id)
            XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, expected)
            store.closeRebasedOverlay(session.id, id: opened.overlay)
        }
    }

    func testHiddenRebasedPanelsHaveNoChromeOrHitTesting() throws {
        let (store, session) = try addSession()
        let overlay = RebasedOverlay(project: "/repo")
        XCTAssertNil(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: 60))
        XCTAssertTrue(store.setRebasedHidden(session.id, id: overlay.id, true))
        let style = OverlayPanelStyle.resolve(session)
        XCTAssertFalse(style.framed)
        XCTAssertFalse(style.backdrop)
        XCTAssertFalse(style.interactive)
        XCTAssertEqual(style.borderOpacity, 0)
        XCTAssertEqual(style.shadowRadius, 0)
        XCTAssertFalse(OverlayPanelStyle.sessionHitTesting(session, live: true, hostsSurface: true))
        XCTAssertNil(RebasedSlot.message(for: try XCTUnwrap(session.rebasedOverlay), shownElsewhere: true))
        store.closeOverlay(session.id)
        store.toggleSplit(session.id)
        XCTAssertNil(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .left))
        XCTAssertTrue(store.setRebasedHidden(session.id, id: overlay.id, true))
        XCTAssertFalse(session.paneOverlayCovers(.left))
        XCTAssertFalse(OverlayPanelStyle.paneHitTesting(session, pane: .left, visible: true, active: true))
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

    func testToggleForAGivenSessionHidesThatSessionsOverlay() throws {
        let (store, session) = try addSession()
        let (_, other) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        store.selectSession(other.id)
        XCTAssertEqual(actions.toggleRebasedOverlay(session: session.id), .hidden)
        XCTAssertEqual(session.rebasedOverlay?.hidden, true)
        XCTAssertFalse(other.overlayActive)
    }
}
