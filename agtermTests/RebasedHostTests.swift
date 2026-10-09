import AppKit
import XCTest
@testable import agterm
import agtermCore

final class FakeRebasedRuntime: RebasedRuntime, @unchecked Sendable {
    var startError: (any Error)?
    var binds: [RebasedRuntimeError?] = [nil]
    var created = false
    private(set) var starts = 0
    private(set) var calls: [String] = []

    func prepare(appPath: String, stateDirectory: URL) throws -> RebasedLaunch {
        RebasedLaunch(libjvm: "", options: [], mainClass: "")
    }

    func launch(_ launch: RebasedLaunch) throws {
        starts += 1
        if let startError { throw startError }
        created = true
    }

    func bindEvents() -> RebasedRuntimeError? { binds.count > 1 ? binds.removeFirst() : binds.first ?? nil }
    var saveGate: DispatchSemaphore?

    func call(_ command: String, _ argument: String) -> String {
        if command == "saveAll", let saveGate {
            saveGate.wait()
            return "ok"
        }
        calls.append("\(command) \(argument)")
        return "ok"
    }

    var jvmCreated: Bool { created }
}

@MainActor
final class FakeRebasedFrames: RebasedFrames {
    private(set) var log: [String] = []
    var names: [ObjectIdentifier: String] = [:]

    private func name(_ window: NSWindow?) -> String { window.flatMap { names[ObjectIdentifier($0)] } ?? "nil" }
    func adopt(_ frame: NSWindow, in host: NSWindow?) { log.append("adopt \(name(frame)) in \(name(host))") }
    func attach(_ window: NSWindow, to host: NSWindow?) { log.append("attach \(name(window)) to \(name(host))") }
    func detach(_ window: NSWindow) { log.append("detach \(name(window))") }
    func orderOut(_ window: NSWindow) { log.append("orderOut \(name(window))") }
    func refit(host: NSWindow) { log.append("refit \(name(host))") }
    func makeKey(_ frame: NSWindow) { log.append("makeKey \(name(frame))") }
}

@MainActor
final class RebasedHostTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var first: Session!
    private var second: Session!
    private var host: RebasedHost!
    private var runtime: FakeRebasedRuntime!
    private var frames: FakeRebasedFrames!
    private var timers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    private var windows: [Int: NSWindow] = [:]
    private var hostWindows: [UUID: NSWindow] = [:]
    private let project = "/tmp"
    private let otherProject = "/usr"

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rebased-host-\(UUID().uuidString)")
        store = AppStore(persistence: PersistenceStore(directory: directory))
        let workspace = store.addWorkspace(name: "work")
        first = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        second = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        runtime = FakeRebasedRuntime()
        frames = FakeRebasedFrames()
        host = RebasedHost()
        host.runtime = runtime
        host.frames = frames
        host.store = { [store] _ in store }
        host.window = { [unowned self] in windows[$0] }
        host.hostWindow = { [unowned self] in hostWindows[$0] }
        host.after = { [unowned self] delay, work in timers.append((delay, work)) }
        host.offMain = { work, done in
            work()
            done()
        }
        host.install()
        hostWindows[first.id] = window("host1")
        hostWindows[second.id] = window("host2")
    }

    override func tearDown() async throws {
        RebasedOverlayReleases.shared.onRelease = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func window(_ name: String, number: Int? = nil) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        frames.names[ObjectIdentifier(window)] = name
        if let number { windows[number] = window }
        return window
    }

    private func open(_ session: Session, project: String? = nil) {
        XCTAssertNil(store.openRebasedOverlay(session.id, overlay: RebasedOverlay(project: project ?? self.project), sizePercent: nil))
        host.setSlotVisible(true, session: session.id)
        host.open(session: session.id)
    }

    private func refusal(_ result: Result<RebasedOpened, RebasedOpenRefusal>) -> String? {
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    private func state(_ session: Session) -> RebasedOverlay.State? { session.rebasedOverlay?.state }

    private func fire(_ delay: TimeInterval) {
        let due = timers.filter { $0.delay == delay }
        timers.removeAll { $0.delay == delay }
        due.forEach { $0.work() }
    }

    private func startAndShow(_ session: Session) {
        open(session)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
    }

    func testAReplacementReporterBeforeTheOldHideKeepsTheFrameShown() throws {
        try checkReporterHandover(newFirst: true)
    }

    func testAReplacementReporterAfterTheOldHideShowsTheFrameAgain() throws {
        try checkReporterHandover(newFirst: false)
    }

    private func checkReporterHandover(newFirst: Bool) throws {
        let id = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil).get().overlay
        let oldReporter = UUID(), newReporter = UUID()
        host.setSlotVisible(true, overlay: id, reporter: oldReporter)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        let before = runtime.calls.filter { $0 == "hide \(project)" }.count
        if newFirst {
            host.setSlotVisible(true, overlay: id, reporter: newReporter)
            host.setSlotVisible(false, overlay: id, reporter: oldReporter)
            XCTAssertEqual(runtime.calls.filter { $0 == "hide \(project)" }.count, before)
        } else {
            host.setSlotVisible(false, overlay: id, reporter: oldReporter)
            host.setSlotVisible(true, overlay: id, reporter: newReporter)
        }
        XCTAssertTrue(host.isShown(in: first.id))
        host.setSlotVisible(false, overlay: id, reporter: newReporter)
        XCTAssertFalse(host.isShown(in: first.id))
    }

    func testShownElsewhereRequiresAnotherVisibleHolder() throws {
        startAndShow(first)
        let firstID = try XCTUnwrap(first.rebasedPlacement?.overlay.id)
        XCTAssertFalse(host.isShownElsewhere(overlay: firstID))
        open(second)
        let secondID = try XCTUnwrap(second.rebasedPlacement?.overlay.id)
        XCTAssertTrue(host.isShownElsewhere(overlay: firstID))
        XCTAssertFalse(host.isShownElsewhere(overlay: secondID))
        host.setSlotVisible(false, session: second.id)
        host.setSlotVisible(false, session: first.id)
        XCTAssertFalse(host.isShownElsewhere(overlay: firstID))
        XCTAssertFalse(host.isShownElsewhere(overlay: secondID))
    }

    private final class MovablePane: PaneRoleMutableSurface {
        let isRealized = true
        let paneToken = UUID().uuidString
        func teardown() {}
        func promoteToPrimaryPane() {}
        func setPaneRole(_ role: SwappablePaneRole) {}
    }

    func testAReporterSwapKeepsTheIDEOnItsMovedPane() throws { try checkPaneMove(swap: true) }
    func testAReporterPromotionKeepsTheIDEOnTheSurvivingPane() throws { try checkPaneMove(swap: false) }

    private func checkPaneMove(swap: Bool) throws {
        let keeper = RebasedFrameKeeper()
        keeper.after = { _, _ in }
        host.frames = keeper
        host.install()
        first.surface = MovablePane()
        store.toggleSplit(first.id)
        first.splitSurface = MovablePane()
        let id = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, pane: .right).get().overlay
        let parent = try XCTUnwrap(hostWindows[first.id])
        let oldReporter = UUID(), newReporter = UUID()
        host.setSlot(NSRect(x: 500, y: 100, width: 300, height: 400), overlay: id, in: parent)
        host.setSlotVisible(true, overlay: id, reporter: oldReporter)
        host.handle(event: "ready", payload: "")
        let frame = window("frame", number: 7)
        defer { keeper.detach(frame); frame.orderOut(nil) }
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        if swap { XCTAssertNil(store.swapPanes(first.id)) } else { store.closePrimaryPane(first.id) }
        XCTAssertEqual(first.rebasedPlacement?.pane, .left)
        let moved = NSRect(x: 100, y: 100, width: 400, height: 400)
        host.setSlot(moved, overlay: id, in: parent)
        host.setSlotVisible(true, overlay: id, reporter: newReporter)
        host.setSlotVisible(false, overlay: id, reporter: oldReporter)
        XCTAssertTrue(host.isShown(in: first.id))
        XCTAssertEqual(first.rebasedPlacement?.overlay.id, id)
        XCTAssertEqual(frame.frame, moved)
    }

    func testAPaneHolderReceivesStateAndFrameCloseReleasesThatPane() throws {
        store.toggleSplit(first.id)
        let opened = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, pane: .left).get()
        XCTAssertEqual(first.leftOverlay?.rebased?.id, opened.overlay)
        XCTAssertNil(first.rebasedOverlay)
        host.setSlotVisible(true, session: first.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertEqual(first.leftOverlay?.rebased?.state, .shown)
        XCTAssertTrue(host.isShown(in: first.id))
        XCTAssertEqual(frames.log.last, "adopt frame in host1")
        host.handle(event: "frameClosed", payload: project)
        XCTAssertNil(first.leftOverlay)
        XCTAssertNotNil(store.session(withID: first.id))
    }

    func testRemotePanePlaceholderKeepsItsQueuedViewAcrossTheFetch() throws {
        let (remote, _) = try remoteRow(refresh: .success(mirrored))
        store.toggleSplit(remote.id)
        var pending: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.offMain = { work, done in pending.append((work, done)) }
        let opened = try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil, pane: .left).get()
        let view = RebasedViewRequest(view: .file(path: "/repo/a", line: 1))
        XCTAssertTrue(remote.updateRebasedOverlay(opened.overlay) { $0.view = view })
        let (work, done) = try XCTUnwrap(pending.first)
        work()
        done()
        XCTAssertNil(remote.rebasedOverlay)
        XCTAssertEqual(remote.leftOverlay?.rebased?.id, opened.overlay)
        XCTAssertEqual(remote.leftOverlay?.rebased?.project, mirrored.directory)
        XCTAssertEqual(remote.leftOverlay?.rebased?.source, mirrored.source)
        XCTAssertEqual(remote.leftOverlay?.rebased?.view, view)
        XCTAssertEqual(remote.leftOverlay?.rebased?.state, .starting)
    }

    func testExplicitProjectBypassesGitDiscoveryAndReuseChecksThePane() throws {
        let nested = directory.appendingPathComponent("repo/sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        store.toggleSplit(first.id)
        let opened = try host.openOverlay(in: store, session: first.id, cwd: "/elsewhere", sizePercent: nil,
                                          pane: .left, project: nested.path).get()
        XCTAssertEqual(first.leftOverlay?.rebased?.project, nested.path)
        let implicitPane = try host.openOverlay(in: store, session: first.id, cwd: nil, sizePercent: nil, project: nested.path).get()
        let samePane = try host.openOverlay(in: store, session: first.id, cwd: nil, sizePercent: nil, pane: .left, project: nested.path).get()
        XCTAssertEqual(implicitPane.overlay, opened.overlay)
        XCTAssertEqual(samePane.overlay, opened.overlay)
        XCTAssertNotNil(refusal(host.openOverlay(in: store, session: first.id, cwd: nil, sizePercent: nil, pane: .right, project: nested.path)))
        XCTAssertEqual(first.leftOverlay?.rebased?.id, opened.overlay)
    }

    func testTheFrameFitsItsCurrentHolderAmongTwoSlotsOnOneWindow() throws {
        let keeper = RebasedFrameKeeper()
        keeper.after = { _, _ in }
        host.frames = keeper
        host.install()
        let parent = try XCTUnwrap(hostWindows[first.id])
        hostWindows[second.id] = parent
        store.toggleSplit(first.id)
        store.toggleSplit(second.id)
        let firstID = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, pane: .left).get().overlay
        let left = NSRect(x: 100, y: 100, width: 400, height: 300)
        host.setSlot(left, overlay: firstID, in: parent)
        host.setSlotVisible(true, session: first.id)
        host.handle(event: "ready", payload: "")
        let frame = window("frame", number: 7)
        defer { keeper.detach(frame); frame.orderOut(nil) }
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertEqual(frame.frame, left)
        let secondID = try host.openOverlay(in: store, session: second.id, cwd: project, sizePercent: nil, pane: .right).get().overlay
        let right = NSRect(x: 500, y: 100, width: 350, height: 300)
        host.setSlot(right, overlay: secondID, in: parent)
        host.setSlotVisible(true, session: second.id)
        XCTAssertEqual(frame.frame, right)
        let resized = NSRect(x: 450, y: 100, width: 400, height: 300)
        host.setSlot(resized, overlay: secondID, in: parent)
        XCTAssertEqual(frame.frame, resized)
        host.setSlotVisible(false, session: second.id)
        XCTAssertEqual(frame.frame, left)
    }

    func testOpenStartsBindsOpensAndShowsTheFrame() {
        runtime.binds = [.notReady, nil]
        open(first)
        XCTAssertEqual(runtime.starts, 1)
        XCTAssertEqual(host.jvm, .starting)
        XCTAssertEqual(state(first), .starting)
        fire(0.25)
        host.handle(event: "ready", payload: "")
        XCTAssertEqual(runtime.calls, ["open \(project)"])
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "/private/tmp\t7")
        XCTAssertEqual(state(first), .shown)
        XCTAssertTrue(host.isShown(in: first.id))
        XCTAssertEqual(frames.log, ["adopt frame in host1"])
        XCTAssertEqual(runtime.calls.last, "show \(project)")
        XCTAssertEqual(host.status, ControlRebasedNode(jvm: "running", projects: [project]))
    }

    private let range = RebasedDiff(base: "main", head: "HEAD", mergeBase: true)
    private var diffCall: String { "diff main\tHEAD\t1\t\(project)" }

    func testADiffOpensOnceTheFrameIsShown() {
        XCTAssertNil(store.openRebasedOverlay(first.id, overlay: RebasedOverlay(project: project, diff: range), sizePercent: nil))
        host.setSlotVisible(true, session: first.id)
        host.open(session: first.id)
        host.handle(event: "ready", payload: "")
        XCTAssertFalse(runtime.calls.contains(diffCall))
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertEqual(runtime.calls.suffix(2), ["show \(project)", diffCall])
        host.setSlotVisible(false, session: first.id)
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(runtime.calls.filter { $0 == diffCall }.count, 1)
    }

    func testADiffOnTheOpenOverlayIsSentAtOnceAndRecorded() {
        startAndShow(first)
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, diff: range).get())
        XCTAssertEqual(runtime.calls.last, diffCall)
        XCTAssertEqual(first.rebasedOverlay?.diff, range)
        XCTAssertEqual(state(first), .shown)
    }

    func testADiffWaitsWhileTheSlotIsHidden() {
        startAndShow(first)
        host.setSlotVisible(false, session: first.id)
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, diff: range).get())
        XCTAssertFalse(runtime.calls.contains(diffCall))
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(runtime.calls.last, diffCall)
    }

    func testADiffOnAnotherProjectIsRefusedLikeAnyOpen() {
        startAndShow(first)
        XCTAssertEqual(refusal(host.openOverlay(in: store, session: first.id, cwd: otherProject, sizePercent: nil, diff: range)),
                       RebasedOverlayOpenFailure.alreadyOpen.message)
        XCTAssertNil(first.rebasedOverlay?.diff)
    }

    // MARK: Remote rows

    private func remoteRow(refresh: Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure>) throws -> (Session, MirrorCalls) {
        let workspace = store.addWorkspace(name: "remote")
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "p4linux"))
        hostWindows[session.id] = window("remote")
        let calls = MirrorCalls()
        host.mirrorRefresh = { mirror, _ in
            calls.append(mirror)
            return refresh
        }
        return (session, calls)
    }

    private let mirrored = RebasedMirrorRefresh.Copy(directory: "/tmp", source: "p4linux:/home/s/repo")

    func testARemoteRowFetchesThenOpensTheMirror() throws {
        let (remote, calls) = try remoteRow(refresh: .success(mirrored))
        var pending: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.offMain = { work, done in pending.append((work, done)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo/sub", sizePercent: nil, diff: range).get())
        XCTAssertEqual(remote.rebasedOverlay?.state, .fetching)
        XCTAssertEqual(remote.rebasedOverlay?.source, "p4linux:/home/s/repo/sub")
        XCTAssertEqual(refusal(host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil, diff: range)),
                       "Rebased is still fetching from p4linux")
        let id = remote.rebasedOverlay?.id
        let (work, done) = try XCTUnwrap(pending.first)
        work()
        done()
        XCTAssertEqual(calls.paths, ["/home/s/repo/sub"])
        XCTAssertEqual(remote.rebasedOverlay, RebasedOverlay(project: project, diff: range, source: "p4linux:/home/s/repo", id: try XCTUnwrap(id)))
        XCTAssertEqual(host.jvm, .starting)
    }

    func testAFailedFetchFailsTheOverlayWithoutStartingTheIDE() throws {
        let (remote, _) = try remoteRow(refresh: .failure(.init(message: "p4linux found no repository at /home/s: exit 128")))
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s", sizePercent: nil).get())
        XCTAssertEqual(remote.rebasedOverlay?.state, .failed("p4linux found no repository at /home/s: exit 128"))
        XCTAssertEqual(runtime.starts, 0)
    }

    func testARangeOnAnOpenRemoteOverlayRefreshesTheMirrorFirst() throws {
        let (remote, calls) = try remoteRow(refresh: .success(mirrored))
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        host.setSlotVisible(true, session: remote.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil, diff: range).get())
        XCTAssertEqual(calls.paths, ["/home/s/repo", "/home/s/repo"])
        XCTAssertEqual(runtime.calls.last, diffCall)
        XCTAssertEqual(refusal(host.openOverlay(in: store, session: remote.id, cwd: "/home/s/other", sizePercent: nil, diff: range)),
                       RebasedOverlayOpenFailure.alreadyOpen.message)
        XCTAssertEqual(calls.paths.count, 2)
    }

    func testAFailedRefreshUnderAnOpenIDESendsNoRange() throws {
        let (remote, _) = try remoteRow(refresh: .success(mirrored))
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        host.setSlotVisible(true, session: remote.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        host.mirrorRefresh = { _, _ in .failure(.init(message: "offline")) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil, diff: range).get())
        XCTAssertFalse(runtime.calls.contains(diffCall))
        XCTAssertEqual(remote.rebasedOverlay?.state, .shown)
    }

    func testAnOverlayClosedWhileFetchingStaysClosed() throws {
        let (remote, _) = try remoteRow(refresh: .success(mirrored))
        var pending: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.offMain = { work, done in pending.append((work, done)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        store.closeOverlay(remote.id)
        let (work, done) = try XCTUnwrap(pending.first)
        work()
        done()
        XCTAssertNil(remote.rebasedOverlay)
        XCTAssertEqual(runtime.starts, 0)
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
    }

    func testFailedStartFailsTheOverlayAndARetryStartsAgain() {
        runtime.startError = RebasedRuntimeError.failed("dlopen failed")
        open(first)
        XCTAssertEqual(state(first), .failed("dlopen failed"))
        XCTAssertEqual(host.status, ControlRebasedNode(jvm: "failed", error: "dlopen failed"))
        store.closeOverlay(first.id)
        runtime.startError = nil
        open(first)
        XCTAssertEqual(runtime.starts, 2)
        XCTAssertEqual(host.jvm, .starting)
    }

    func testDeadlineFailsTheOverlayAndALateReadyServesTheRetryWithoutAStart() {
        open(first)
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(first), .failed(RebasedHost.deadlineMessage))
        XCTAssertEqual(host.jvm, .starting)
        host.handle(event: "ready", payload: "")
        XCTAssertEqual(host.jvm, .running)
        store.closeOverlay(first.id)
        open(first)
        XCTAssertEqual(runtime.starts, 1)
        XCTAssertEqual(runtime.calls, ["open \(project)"])
        XCTAssertEqual(state(first), .starting)
    }

    func testAShownOverlayIsNotFailedByTheDeadline() {
        startAndShow(first)
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(first), .shown)
    }

    func testFailedCreatedJVMFailsANewOpenAtOnce() {
        open(first)
        host.handle(event: "failed", payload: "main threw")
        store.closeOverlay(first.id)
        open(first)
        XCTAssertEqual(state(first), .failed("main threw"))
        XCTAssertEqual(runtime.starts, 1)
    }

    func testFrameClosedClosesEveryOverlayOnThatProject() {
        startAndShow(first)
        open(second)
        host.handle(event: "frameClosed", payload: project)
        XCTAssertNil(first.rebasedOverlay)
        XCTAssertNil(second.rebasedOverlay)
        XCTAssertEqual(host.status.projects, [])
    }

    func testReleaseHidesTheFrame() {
        startAndShow(first)
        store.closeOverlay(first.id)
        XCTAssertEqual(runtime.calls.last, "hide \(project)")
        XCTAssertEqual(frames.log.last, "detach frame")
        XCTAssertFalse(host.isShown(in: first.id))
    }

    func testOneFrameOnePlace() {
        startAndShow(first)
        open(second)
        XCTAssertEqual(frames.log.last, "adopt frame in host2")
        XCTAssertTrue(host.isShown(in: second.id))
        XCTAssertFalse(host.isShown(in: first.id))
        XCTAssertEqual(state(first), .shown)
    }

    func testLaterWindowsAttachWhileVisible() {
        startAndShow(first)
        _ = window("dialog", number: 8)
        host.handle(event: "windowOpened", payload: "8\tdialog")
        XCTAssertEqual(frames.log.last, "attach dialog to host1")
    }

    func testADialogWhileHiddenShowsTheLastSessionAgain() {
        startAndShow(first)
        host.hide(session: first.id)
        _ = window("dialog", number: 8)
        host.handle(event: "windowOpened", payload: "8\tdialog")
        XCTAssertEqual(Array(frames.log.suffix(2)), ["adopt frame in host1", "attach dialog to host1"])
        XCTAssertTrue(host.isShown(in: first.id))
    }

    func testAPopupWhileHiddenAndTheWelcomeFrameAreOrderedOut() {
        startAndShow(first)
        host.hide(session: first.id)
        _ = window("popup", number: 8)
        host.handle(event: "windowOpened", payload: "8\tpopup")
        XCTAssertEqual(frames.log.last, "orderOut popup")
        host.show(session: first.id)
        _ = window("welcome", number: 9)
        host.handle(event: "windowOpened", payload: "9\twelcome")
        XCTAssertEqual(frames.log.last, "orderOut welcome")
    }

    func testIDEKeyWindowOverride() {
        host.isIDEKeyWindowOverride = true
        XCTAssertTrue(host.isIDEKeyWindow)
        host.isIDEKeyWindowOverride = false
        XCTAssertFalse(host.isIDEKeyWindow)
    }

    func testAnOpenDuringStartupGetsItsOwnDeadlineEvenAfterTheFirstIsReleased() {
        runtime.binds = [.notReady]
        open(first)
        open(second)
        store.closeOverlay(first.id)
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(second), .failed(RebasedHost.deadlineMessage))
    }

    func testTheDeadlineRunsWhileLaunchIsStillPendingAndALateLaunchServesTheRetry() {
        var pending: [(work: @Sendable () -> Void, done: @MainActor @Sendable () -> Void)] = []
        host.offMain = { work, done in pending.append((work, done)) }
        func runNext() {
            let next = pending.removeFirst()
            next.work()
            next.done()
        }
        open(first)
        runNext()
        XCTAssertEqual(pending.count, 1, "launch is in flight")
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(first), .failed(RebasedHost.deadlineMessage))
        runNext()
        host.handle(event: "ready", payload: "")
        XCTAssertEqual(host.jvm, .running)
        store.closeOverlay(first.id)
        open(first)
        XCTAssertEqual(runtime.starts, 1)
        XCTAssertEqual(runtime.calls, ["open \(project)"])
    }

    func testALateFrameStaysHiddenAndServesTheRetry() {
        open(first)
        host.handle(event: "ready", payload: "")
        fire(RebasedHost.readyDeadline)
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertEqual(state(first), .failed(RebasedHost.deadlineMessage))
        XCTAssertEqual(runtime.calls.last, "hide \(project)")
        XCTAssertTrue(frames.log.isEmpty)
        store.closeOverlay(first.id)
        open(first)
        XCTAssertEqual(state(first), .shown)
        XCTAssertEqual(frames.log, ["adopt frame in host1"])
        XCTAssertEqual(runtime.starts, 1)
    }

    func testAFailedEventIsNotRevivedByItsFrame() {
        open(first)
        host.handle(event: "failed", payload: "main threw")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertEqual(state(first), .failed("main threw"))
        XCTAssertTrue(frames.log.isEmpty)
    }

    func testDialogsGoToTheirOwnProject() {
        open(first)
        open(second, project: otherProject)
        host.handle(event: "ready", payload: "")
        _ = window("frameA", number: 7)
        _ = window("frameB", number: 8)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        host.handle(event: "frameOpened", payload: "\(otherProject)\t8")
        _ = window("dialogB", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t\(otherProject)")
        XCTAssertEqual(frames.log.last, "attach dialogB to host2")
        host.hide(session: first.id)
        _ = window("dialogA", number: 10)
        host.handle(event: "windowOpened", payload: "10\tdialog\t\(project)")
        XCTAssertEqual(Array(frames.log.suffix(2)), ["adopt frameA in host1", "attach dialogA to host1"])
        XCTAssertTrue(host.isShown(in: first.id))
    }

    func testADialogBeforeAnyFrameAttachesToTheOpeningSlot() {
        open(first)
        host.handle(event: "ready", payload: "")
        _ = window("trust", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t")
        XCTAssertEqual(frames.log.last, "attach trust to host1")
    }

    func testADialogOfAClosedProjectDoesNotRestoreTheSessionsNewProject() {
        startAndShow(first)
        store.closeOverlay(first.id)
        open(first, project: otherProject)
        _ = window("frameB", number: 8)
        host.handle(event: "frameOpened", payload: "\(otherProject)\t8")
        host.hide(session: first.id)
        let before = frames.log.count
        _ = window("dialogA", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t\(project)")
        XCTAssertEqual(Array(frames.log.dropFirst(before)), ["orderOut dialogA"])
        XCTAssertFalse(host.isShown(in: first.id))
    }

    func testAFrameWaitsForASlotThatNeverReportedVisible() {
        XCTAssertNil(store.openRebasedOverlay(first.id, overlay: RebasedOverlay(project: project), sizePercent: nil))
        host.open(session: first.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertFalse(host.isShown(in: first.id))
        XCTAssertTrue(frames.log.isEmpty)
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(frames.log, ["adopt frame in host1"])
    }

    func testReopeningAKnownFrameIntoAHiddenSlotWaits() {
        startAndShow(first)
        store.closeOverlay(first.id)
        host.setSlotVisible(false, session: first.id)
        let before = frames.log.count
        XCTAssertNil(store.openRebasedOverlay(first.id, overlay: RebasedOverlay(project: project), sizePercent: nil))
        host.open(session: first.id)
        XCTAssertEqual(frames.log.count, before)
        XCTAssertFalse(host.isShown(in: first.id))
        XCTAssertEqual(state(first), .shown, "the frame is ready, only off screen")
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(first), .shown)
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(frames.log.last, "adopt frame in host1")
        XCTAssertEqual(runtime.starts, 1)
    }

    func testTheToggleFromAnIDEWindowTargetsTheSessionThatOwnsIt() throws {
        open(first)
        open(second, project: otherProject)
        host.handle(event: "ready", payload: "")
        _ = window("frameA", number: 7)
        let frameB = window("frameB", number: 8)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        host.handle(event: "frameOpened", payload: "\(otherProject)\t8")
        host.keyWindow = { frameB }
        host.isIDEKeyWindowOverride = true
        host.keymap = { parseKeymap("map ctrl+shift+r rebased_toggle").keymap }
        var toggled: [UUID?] = []
        host.toggle = { toggled.append($0) }
        let chord = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "r", charactersIgnoringModifiers: "r",
                                                   isARepeat: false, keyCode: 15))
        XCTAssertNil(host.route(chord))
        XCTAssertEqual(toggled, [second.id])
    }

    func testQuitSaveReturnsAtItsDeadlineWhenTheBridgeStalls() {
        startAndShow(first)
        let gate = DispatchSemaphore(value: 0)
        runtime.saveGate = gate
        let start = Date()
        XCTAssertFalse(host.saveBeforeQuit(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(host.saveBeforeQuit(timeout: 0.2), "a timed-out save is not issued twice")
        gate.signal()
    }

    func testADialogUnderACoverWaitsUntilTheSlotIsVisibleAgain() {
        startAndShow(first)
        host.setSlotVisible(false, session: first.id)
        let before = frames.log.count
        _ = window("dialog", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t\(project)")
        XCTAssertEqual(Array(frames.log.dropFirst(before)), ["orderOut dialog"])
        XCTAssertFalse(host.isShown(in: first.id))
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(Array(frames.log.suffix(2)), ["adopt frame in host1", "attach dialog to host1"])
    }

    func testAQueuedDialogOfAReleasedOverlayComesUpOnceAtRelease() {
        startAndShow(first)
        host.setSlotVisible(false, session: first.id)
        _ = window("dialogA", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t\(project)")
        store.closeOverlay(first.id)
        XCTAssertEqual(frames.log.last, "attach dialogA to host1")
        open(first, project: otherProject)
        _ = window("frameB", number: 8)
        host.handle(event: "frameOpened", payload: "\(otherProject)\t8")
        XCTAssertEqual(frames.log.last, "adopt frameB in host1")
        XCTAssertEqual(frames.log.filter { $0 == "attach dialogA to host1" }.count, 1)
    }

    func testClosingTheOwnerHandsTheFrameToAnotherVisibleHolder() {
        startAndShow(first)
        open(second)
        XCTAssertEqual(frames.log.last, "adopt frame in host2")
        store.closeOverlay(second.id)
        XCTAssertEqual(frames.log.last, "adopt frame in host1")
        XCTAssertTrue(host.isShown(in: first.id))
    }

    func testHidingTheOwnersSlotHandsTheFrameToAnotherVisibleHolder() {
        startAndShow(first)
        open(second)
        host.setSlotVisible(false, session: second.id)
        XCTAssertEqual(frames.log.last, "adopt frame in host1")
        XCTAssertTrue(host.isShown(in: first.id))
    }

    func testADialogBeforeAnyFrameWaitsForItsHiddenOpeningSlot() {
        XCTAssertNil(store.openRebasedOverlay(first.id, overlay: RebasedOverlay(project: project), sizePercent: nil))
        host.open(session: first.id)
        host.handle(event: "ready", payload: "")
        _ = window("trust", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t")
        XCTAssertEqual(frames.log.last, "orderOut trust")
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(frames.log.last, "attach trust to host1")
    }

    func testADialogBeforeAnyFrameIgnoresAnotherVisibleProject() {
        startAndShow(first)
        XCTAssertNil(store.openRebasedOverlay(second.id, overlay: RebasedOverlay(project: otherProject), sizePercent: nil))
        host.open(session: second.id)
        _ = window("trust", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t")
        XCTAssertEqual(frames.log.last, "orderOut trust")
    }

    func testARepeatedFrameReportKeepsTheFrameShown() {
        startAndShow(first)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertTrue(host.isShown(in: first.id))
        XCTAssertEqual(runtime.calls.last, "show \(project)")
    }

    func testAnotherIDEWindowIsMadeVisibleAgain() {
        startAndShow(first)
        let editor = window("editor", number: 8)
        editor.alphaValue = 0
        host.handle(event: "windowOpened", payload: "8\tpopup")
        XCTAssertEqual(editor.alphaValue, 1)
        XCTAssertEqual(frames.log.last, "attach editor to host1")
    }

    func testAProjectPathWithATabStillParses() {
        let tabbed = "/tmp/a\tb"
        open(first, project: tabbed)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(tabbed)\t7")
        XCTAssertTrue(host.isShown(in: first.id))
        _ = window("dialog", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t\(tabbed)")
        XCTAssertEqual(frames.log.last, "attach dialog to host1")
    }

    func testTheProjectIsTheNearestDirectoryHoldingGit() throws {
        let manager = FileManager.default
        let repo = directory.appendingPathComponent("repo ")
        let deeper = repo.appendingPathComponent("sub/deeper")
        try manager.createDirectory(at: deeper, withIntermediateDirectories: true)
        try manager.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let worktree = directory.appendingPathComponent("wt")
        try manager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere".utf8).write(to: worktree.appendingPathComponent(".git"))
        let plain = directory.appendingPathComponent("plain")
        try manager.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertEqual(RebasedHost.projectDirectory(for: deeper.path), repo.path)
        XCTAssertEqual(RebasedHost.projectDirectory(for: repo.path + "/"), repo.path)
        XCTAssertEqual(RebasedHost.projectDirectory(for: worktree.path), worktree.path)
        XCTAssertEqual(RebasedHost.projectDirectory(for: plain.path), plain.path)
    }

    func testAPendingAskHidesTheSlot() {
        XCTAssertTrue(RebasedSlot.isVisible(true, session: first))
        first.openAsk(PendingAsk(id: "a", title: "t", buttons: []))
        XCTAssertFalse(RebasedSlot.isVisible(true, session: first))
        XCTAssertFalse(RebasedSlot.isVisible(false, session: second))
    }

    func testASecondHolderOfTheStateDirectoryIsRefused() throws {
        let state = directory.appendingPathComponent("rebased")
        let held = try RebasedStateLock.lock(state)
        defer { close(held) }
        XCTAssertThrowsError(try RebasedStateLock.lock(state)) { error in
            XCTAssertEqual(error as? RebasedRuntimeError, .failed(RebasedStateLock.message))
        }
    }

    func testADialogQueuedPastTheStartupDeadlineStillComesUp() {
        XCTAssertNil(store.openRebasedOverlay(first.id, overlay: RebasedOverlay(project: project), sizePercent: nil))
        host.open(session: first.id)
        _ = window("trust", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t")
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(first), .failed(RebasedHost.deadlineMessage))
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(frames.log.last, "attach trust to host1")
    }
}

final class MirrorCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var mirrors: [RebasedMirror] = []

    func append(_ mirror: RebasedMirror) { lock.withLock { mirrors.append(mirror) } }

    var paths: [String] { lock.withLock { mirrors.map(\.path) } }
}
