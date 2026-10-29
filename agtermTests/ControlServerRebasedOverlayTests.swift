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
        host.onMirrorQueue = { work, done in
            work()
            done()
        }
        host.stateDirectory = stateDir
        host.mirrorRefresh = { _, _, _ in .failure(.init(message: "no refresh in this test")) }
        host.install()
        RebasedHost.shared = host
    }

    override func tearDown() async throws {
        RebasedHost.shared = previousHost
        RebasedOverlayReleases.shared.onRelease = nil
        RebasedOverlayReleases.shared.onHiddenChange = nil
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
        XCTAssertTrue(session.rebasedHidden)
        let queued = server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: "/a", line: 0))
        XCTAssertTrue(queued.ok)
        XCTAssertEqual(session.rebasedPlacement?.overlay.view?.state, .queued)
        let shown = server.toggleRebasedOverlay(session.id.uuidString, window: nil)
        XCTAssertEqual(shown.result?.text, "shown")
        XCTAssertEqual(shown.result?.overlay, id)
        XCTAssertEqual(session.rebasedOverlay?.view?.state, .sent)
        store.closeOverlay(session.id)
        XCTAssertTrue(store.openOverlay(session.id, command: "reader"))
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).error, "overlay already open")
    }

    func testToggleClosesAFailedOverlaySoTheNextPressRetries() throws {
        let (_, session) = try addSession()
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).result?.text, "opened")
        let id = try XCTUnwrap(session.rebasedPlacement?.overlay.id)
        session.updateRebasedOverlay(id) { $0.state = .failed("Rebased did not start within 30 s") }
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).result?.text, "closed")
        XCTAssertNil(session.rebasedPlacement)
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).result?.text, "opened")
    }

    func testWithoutMutagenRemoteRowsRefuseLocalFlagsButStillOpenAndShowDiffs() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/repo", remoteHost: "remote"))
        let diff = RebasedDiff(base: "A", head: "HEAD", mergeBase: false)
        let options: [(String, ControlSessionOverlayOpenOptions)] = [
            ("working-tree", .init(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true, rebasedView: .diff(diff, workingTree: true))),
            ("file", .init(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true, rebasedView: .file(path: "/repo/a", line: 0))),
            ("project", .init(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true, rebasedProject: "/repo")),
        ]
        for (flag, options) in options {
            let synced = ["working-tree", "file"].contains(flag)
            XCTAssertEqual(server.openSessionOverlay(session.id.uuidString, window: nil, options: options).error,
                           synced ? "--\(flag) on a remote row needs mutagen on this Mac" : "--\(flag) works on a local row only")
            XCTAssertNil(session.rebasedPlacement)
        }
        let directory = stateDir.path
        RebasedHost.shared.mirrorRefresh = { _, _, _ in .success(.init(directory: directory, source: "remote:/repo")) }
        let opened = server.openSessionOverlay(session.id.uuidString, window: nil,
            options: .init(command: "", cwd: "/repo", wait: false, sizePercent: nil, backgroundColor: nil, rebased: true,
                           rebasedView: .diff(diff, workingTree: false)))
        XCTAssertTrue(opened.ok, opened.error ?? "")
        frameOpened(session)
        XCTAssertEqual(server.showRebasedView(session.id.uuidString, window: nil, view: .diff(diff, workingTree: true)).error,
                       "--working-tree on a remote row needs mutagen on this Mac")
        XCTAssertEqual(server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: "/repo/a", line: 0)).error,
                       "--file on a remote row needs mutagen on this Mac")
        let shown = server.showRebasedView(session.id.uuidString, window: nil, view: .diff(diff, workingTree: false))
        XCTAssertTrue(shown.ok, shown.error ?? "")
        XCTAssertNotEqual(shown.result?.request, opened.result?.request)
    }

    func testWithMutagenARemoteRowRefreshesForEveryViewAndSendsTheFileInsideTheMirror() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/repo", remoteHost: "remote"))
        RebasedHost.shared.sync = RebasedMirrorRefresh.Sync(binary: { "/fake/mutagen" }, run: { _, _ in .init(status: 0, stdout: "[]", reason: "") })
        let refreshes = Recorder<String>()
        let directory = stateDir.path
        RebasedHost.shared.mirrorRefresh = { mirror, _, _ in
            refreshes.append(mirror.path)
            return .success(.init(directory: directory, source: "remote:/repo"))
        }
        let opened = server.openSessionOverlay(session.id.uuidString, window: nil,
            options: .init(command: "", cwd: "/repo", wait: false, sizePercent: nil, backgroundColor: nil, rebased: true,
                           rebasedView: .diff(RebasedDiff(base: "A", head: "HEAD", mergeBase: false), workingTree: true)))
        XCTAssertTrue(opened.ok, opened.error ?? "")
        frameOpened(session)
        XCTAssertEqual(refreshes.items.count, 1)

        let shown = server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: "/repo/src/../a.kt", line: 3))
        let request = try XCTUnwrap(shown.result?.request, shown.error ?? "")
        XCTAssertEqual(refreshes.items.count, 2)
        XCTAssertEqual(session.rebasedOverlay?.view?.view.target, "/repo/src/../a.kt")
        XCTAssertEqual(runtime.calls.last, "openFile \(request)\t3\t\(RebasedHost.canonical(directory))/a.kt\t\(RebasedHost.canonical(directory))")
        RebasedHost.shared.handle(event: "viewOpened", payload: "\(request)\tok")
        XCTAssertEqual(session.rebasedOverlay?.view?.id, request)
        XCTAssertEqual(session.rebasedOverlay?.view?.state, .opened)

        let outside = server.showRebasedView(session.id.uuidString, window: nil, view: .file(path: "/repo2/a.kt", line: 1))
        let refused = try XCTUnwrap(outside.result?.request)
        XCTAssertEqual(session.rebasedOverlay?.view?.id, refused)
        XCTAssertEqual(session.rebasedOverlay?.view?.state, .failed)
        XCTAssertEqual(session.rebasedOverlay?.view?.detail, "--file /repo2/a.kt is outside remote:/repo")
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
        let page = HtmlOverlay(source: .file(path: "/tmp/review-cover.html", grantRoot: nil))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil))
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
        XCTAssertNil(store.setRebasedHidden(session.id, id: overlay.id, true))
        XCTAssertFalse(visible())
        XCTAssertNil(store.setRebasedHidden(session.id, id: overlay.id, false))
        XCTAssertTrue(visible())
    }

    func testShownElsewhereMessageNeedsAnotherHolderAndLocalVisibility() {
        let overlay = RebasedOverlay(project: "/repo", state: .shown)
        XCTAssertEqual(RebasedSlot.message(for: overlay, shownElsewhere: true), "Rebased is shown in another session")
        XCTAssertNil(RebasedSlot.message(for: overlay, shownElsewhere: false))
        XCTAssertNil(RebasedSlot.message(for: overlay, shownElsewhere: true, visible: false))
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

    func testTheLastCloseOfAProjectClosesItInTheIDE() throws {
        let project = RebasedHost.canonical(stateDir.path)
        let (_, first) = try addSession()
        let (_, second) = try addSession()
        XCTAssertTrue(openRebased(first).ok)
        frameOpened(first)
        XCTAssertTrue(openRebased(second).ok)
        XCTAssertTrue(server.closeSessionOverlay(first.id.uuidString, window: nil, pane: nil).ok)
        XCTAssertNil(first.rebasedOverlay)
        XCTAssertFalse(runtime.calls.contains("close \(project)"))
        XCTAssertTrue(server.closeSessionOverlay(second.id.uuidString, window: nil, pane: nil).ok)
        XCTAssertEqual(runtime.calls.last, "close \(project)")
        XCTAssertTrue(openRebased(first).ok)
        XCTAssertEqual(runtime.calls.last, "open \(project)")
        RebasedHost.shared.handle(event: "frameClosed", payload: stateDir.path)
        XCTAssertNotNil(first.rebasedOverlay)
    }

    func testResizeChangesTheSharedOverlaySize() throws {
        let (_, session) = try addSession()
        XCTAssertTrue(openRebased(session).ok)
        XCTAssertTrue(server.resizeSessionOverlay(session.id.uuidString, window: nil, sizePercent: 55).ok)
        XCTAssertEqual(session.overlaySizePercent, 55)
    }

    func testAProgramOverlayOpensOverAHiddenIDE() throws {
        let (store, session) = try addSession()
        let opened = openRebased(session, sizePercent: 60)
        XCTAssertTrue(opened.ok)
        let id = try XCTUnwrap(opened.result?.overlay)
        frameOpened(session)
        let project = RebasedHost.canonical(stateDir.path)
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).result?.text, "hidden")
        XCTAssertEqual(runtime.calls.last, "hide \(project)")
        let program = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                options: ControlSessionOverlayOpenOptions(command: "true", cwd: nil, wait: false,
                                                                                          sizePercent: nil, backgroundColor: nil))
        XCTAssertTrue(program.ok, program.error ?? "")
        XCTAssertTrue(session.programOverlayActive)
        XCTAssertEqual(runtime.calls.last, "hide \(project)")
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).error, "overlay already open")
        XCTAssertTrue(session.rebasedHidden)
        XCTAssertTrue(store.closeOverlay(session.id))
        let shown = server.toggleRebasedOverlay(session.id.uuidString, window: nil)
        XCTAssertEqual(shown.result?.text, "shown")
        XCTAssertEqual(shown.result?.overlay, id)
        XCTAssertEqual(runtime.calls.last, "show \(project)")
        XCTAssertTrue(session.rebasedOverlayVisible)
        XCTAssertEqual(session.overlaySizePercent, 60)
    }

    func testToggleHidesAndShowsTheSameHolder() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        XCTAssertEqual(actions.toggleRebasedOverlay(), .opened)
        let id = try XCTUnwrap(session.rebasedPlacement?.overlay.id)
        frameOpened(session)
        XCTAssertEqual(actions.toggleRebasedOverlay(), .hidden)
        XCTAssertFalse(session.overlayActive)
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

    func testPaneToggleRefocusesTheUncoveredTerminalAndParksTheHolder() throws {
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
        XCTAssertNil(session.leftOverlay)
        XCTAssertEqual(session.rebasedPlacement?.overlay.id, opened.overlay)
        XCTAssertEqual(session.rebasedPlacement?.pane, .left)
        XCTAssertEqual(runtime.calls.last, "hide \(RebasedHost.canonical(stateDir.path))")
        XCTAssertEqual(server.buildTree(in: store).workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }?.rebasedOverlay?.hidden, true)
        XCTAssertEqual(actions.toggleRebasedOverlay(), .shown)
        XCTAssertEqual(session.leftOverlay?.rebased?.id, opened.overlay)
        XCTAssertEqual(runtime.calls.last, "show \(RebasedHost.canonical(stateDir.path))")
        XCTAssertEqual(server.buildTree(in: store).workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }?.rebasedOverlay?.hidden, false)
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
            if scenario == "shownSession" || scenario == "left" {
                XCTAssertTrue(store.workspaces.flatMap(\.sessions).contains { $0.id == session.id })
                XCTAssertNil(session.rebasedPlacement)
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
        XCTAssertNil(store.setRebasedHidden(session.id, id: opened.overlay, true))
        actions.focusSplitPane(session, wantSplit: false)
        XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, before + 1)
        XCTAssertTrue(session.focusTarget(wantSplit: false) === surface)
    }

    func testAKeyPaneIDEMovesPaneFocusToItsPane() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        store.toggleSplit(session.id)
        session.splitFocused = true
        _ = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path, sizePercent: nil, pane: .left).get()
        frameOpened(session)
        RebasedHost.shared.ideBecameKey(frameWindow)
        XCTAssertFalse(session.splitFocused)
    }

    func testFocusingTheSiblingPaneTakesTheKeyboardBackFromTheIDE() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        store.toggleSplit(session.id)
        session.splitFocused = true
        let hostWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        hostWindow.isReleasedWhenClosed = false
        frames.names[ObjectIdentifier(hostWindow)] = "host"
        RebasedHost.shared.hostWindow = { _ in hostWindow }
        _ = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path, sizePercent: nil, pane: .left).get()
        frameOpened(session)
        RebasedHost.shared.keyWindow = { [frameWindow] in frameWindow }
        RebasedHost.shared.isIDEKeyWindowOverride = true
        actions.focusSplitPane(session, wantSplit: true)
        XCTAssertEqual(frames.log.filter { $0 == "makeKey host" }.count, 1)
        RebasedHost.shared.isIDEKeyWindowOverride = false
        actions.focusSplitPane(session, wantSplit: true)
        XCTAssertEqual(frames.log.filter { $0 == "makeKey host" }.count, 1)
    }

    func testAnOpenOverTheFocusedPaneMakesTheIDEKeyOnce() throws {
        let (store, session) = try addSession()
        let (_, other) = try addSession()
        store.toggleSplit(session.id)
        for target in ["focused", "rightFocused", "otherSession"] {
            store.selectSession(target == "otherSession" ? other.id : session.id)
            session.splitFocused = false
            let opened = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path,
                                                           sizePercent: nil, pane: .left).get()
            session.splitFocused = target == "rightFocused"
            store.selectSession(session.id)
            let before = frames.log.filter { $0 == "makeKey frame" }.count
            frameOpened(session)
            let expected = before + (target == "focused" ? 1 : 0)
            XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, expected)
            RebasedHost.shared.setSlotVisible(false, session: session.id)
            RebasedHost.shared.setSlotVisible(true, session: session.id)
            XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, expected)
            store.closeRebasedOverlay(session.id, id: opened.overlay)
        }
    }

    func testShowingAPaneIDEMakesItKeyOnceOnlyWhenSelectedAndFocused() throws {
        let (store, session) = try addSession()
        let (_, other) = try addSession()
        store.toggleSplit(session.id)
        for target in ["focused", "otherPane", "otherSession"] {
            store.selectSession(session.id)
            session.splitFocused = false
            let opened = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path,
                                                           sizePercent: nil, pane: .left).get()
            frameOpened(session)
            XCTAssertEqual(actions.toggleRebasedOverlay(session: session.id), .hidden)
            RebasedHost.shared.setSlotVisible(false, session: session.id)
            session.splitFocused = target == "otherPane"
            if target == "otherSession" { store.selectSession(other.id) }
            let before = frames.log.filter { $0 == "makeKey frame" }.count
            XCTAssertEqual(actions.toggleRebasedOverlay(session: session.id), .shown)
            XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, before)
            store.selectSession(session.id)
            RebasedHost.shared.setSlotVisible(true, session: session.id)
            let expected = before + (target == "focused" ? 1 : 0)
            XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, expected)
            RebasedHost.shared.setSlotVisible(false, session: session.id)
            RebasedHost.shared.setSlotVisible(true, session: session.id)
            XCTAssertEqual(frames.log.filter { $0 == "makeKey frame" }.count, expected)
            XCTAssertTrue(store.closeRebasedOverlay(session.id, id: opened.overlay))
        }
    }

    func testHiddenRebasedPanelsAreNeitherVisibleNorBackdropped() throws {
        let (store, session) = try addSession()
        let overlay = RebasedOverlay(project: "/repo")
        XCTAssertNil(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: 60))
        XCTAssertNil(store.setRebasedHidden(session.id, id: overlay.id, true))
        XCTAssertFalse(OverlayPanelStyle.resolve(session).backdrop)
        XCTAssertFalse(session.coverOverlayVisible)
        XCTAssertFalse(RebasedSlot.isVisible(true, session: session))
        XCTAssertNil(RebasedSlot.message(for: try XCTUnwrap(session.rebasedPlacement?.overlay), shownElsewhere: true,
                                         visible: RebasedSlot.isVisible(true, session: session)))
        XCTAssertTrue(store.closeRebasedOverlay(session.id, id: overlay.id))
        store.toggleSplit(session.id)
        XCTAssertNil(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .left))
        XCTAssertNil(store.setRebasedHidden(session.id, id: overlay.id, true))
        XCTAssertFalse(session.paneOverlayVisible(.left))
        XCTAssertFalse(RebasedSlot.isVisible(true, session: session, pane: .left))
    }

    func testUpstreamsHideRoutesMoveTheIDEWindowToo() throws {
        let (store, session) = try addSession()
        store.selectSession(session.id)
        store.toggleSplit(session.id)
        session.splitFocused = false
        let surface = FocusSurface()
        session.surface = surface
        _ = try RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: stateDir.path,
                                               sizePercent: nil, pane: .left).get()
        frameOpened(session)
        let project = RebasedHost.canonical(stateDir.path)
        var refocused = false
        actions.rebasedRefocus = { current in refocused = current.topmostSurface === surface }
        actions.toggleOverlays()
        XCTAssertTrue(session.rebasedHidden)
        XCTAssertEqual(runtime.calls.last, "hide \(project)")
        XCTAssertTrue(refocused)
        XCTAssertEqual(server.setSessionOverlayVisibility(session.id.uuidString, window: nil, pane: .left, mode: .show).result?.text,
                       "shown")
        XCTAssertEqual(runtime.calls.last, "show \(project)")
        XCTAssertEqual(server.setSessionOverlayVisibility(session.id.uuidString, window: nil, pane: nil, mode: .toggle).result?.text,
                       "hidden")
        XCTAssertEqual(runtime.calls.last, "hide \(project)")
        let node = server.buildTree(in: store).workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        XCTAssertEqual(node?.rebasedOverlay?.hidden, true)
        XCTAssertEqual(node?.hiddenOverlays, ["left"])
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
        XCTAssertTrue(session.rebasedHidden)
        XCTAssertFalse(other.overlayActive)
    }

    func testARemoteOnCloseIsCapturedForTheHostAndRunsOnceAtRelease() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/repo", remoteHost: "remote"))
        var commands: [RebasedOnClose] = []
        RebasedHost.shared.runOnClose = { commands.append($0) }
        var pending: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        RebasedHost.shared.onMirrorQueue = { work, done in pending.append((work, done)) }
        func open(cwd: String?) -> ControlResponse {
            server.openSessionOverlay(session.id.uuidString, window: nil,
                options: .init(command: "", cwd: cwd, wait: false, sizePercent: nil, backgroundColor: nil, rebased: true,
                               rebasedOnClose: "flush --final"))
        }
        let fetching = open(cwd: nil)
        XCTAssertTrue(fetching.ok, fetching.error ?? "")
        XCTAssertEqual(session.rebasedOverlay?.state, .fetching)
        XCTAssertEqual(session.rebasedOverlay?.onClose,
                       RebasedOnClose(command: "flush --final", cwd: "/repo", environment: [:], host: "remote"))
        XCTAssertEqual(open(cwd: nil).error, "a Rebased overlay is already open in this session; --on-close needs a new one")
        XCTAssertTrue(server.closeSessionOverlay(session.id.uuidString, window: nil,
                                                 overlay: try XCTUnwrap(session.rebasedOverlay?.id)).ok)
        XCTAssertEqual(commands.map(\.host), ["remote"])
        for (work, done) in pending {
            work()
            done()
        }
        XCTAssertEqual(commands.count, 1)

        RebasedHost.shared.onMirrorQueue = { work, done in
            work()
            done()
        }
        let directory = stateDir.path
        RebasedHost.shared.mirrorRefresh = { _, _, _ in .success(.init(directory: directory, source: "remote:/repo")) }
        XCTAssertTrue(open(cwd: "/repo/sub").ok)
        XCTAssertEqual(session.rebasedOverlay?.onClose?.cwd, "/repo/sub")
        frameOpened(session)
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).result?.text, "hidden")
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(server.toggleRebasedOverlay(session.id.uuidString, window: nil).result?.text, "shown")
        XCTAssertTrue(server.closeSessionOverlay(session.id.uuidString, window: nil,
                                                 overlay: try XCTUnwrap(session.rebasedOverlay?.id)).ok)
        XCTAssertEqual(commands.map(\.cwd), ["/repo", "/repo/sub"])
    }
}
