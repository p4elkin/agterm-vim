import AppKit
import XCTest
@testable import agterm
import agtermCore

final class FakeRebasedRuntime: RebasedRuntime, @unchecked Sendable {
    var startError: (any Error)?
    var prepareError: (any Error)?
    var binds: [RebasedRuntimeError?] = [nil]
    var created = false
    private(set) var prepares = 0
    private(set) var starts = 0
    private(set) var calls: [String] = []

    func prepare(appPath: String, stateDirectory: URL) throws -> RebasedLaunch {
        prepares += 1
        if let prepareError { throw prepareError }
        return RebasedLaunch(libjvm: "", options: [], mainClass: "")
    }

    func launch(_ launch: RebasedLaunch) throws {
        starts += 1
        if let startError { throw startError }
        created = true
    }

    func bindEvents() -> RebasedRuntimeError? { binds.count > 1 ? binds.removeFirst() : binds.first ?? nil }
    var saveGate: DispatchSemaphore?
    var answers: [String: [String]] = [:]

    func call(_ command: String, _ argument: String) -> String {
        if command == "saveAll", let saveGate {
            saveGate.wait()
            return "ok"
        }
        calls.append("\(command) \(argument)")
        if var values = answers[command], !values.isEmpty {
            let answer = values.removeFirst()
            answers[command] = values
            return answer
        }
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
    private var prunes: Recorder<RebasedMirrorCleanup.Request>!
    private var runtime: FakeRebasedRuntime!
    private var frames: FakeRebasedFrames!
    private var timers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    private var windows: [Int: NSWindow] = [:]
    private var hostWindows: [UUID: NSWindow] = [:]
    private var clock = Date(timeIntervalSince1970: 1000)
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
        host.onMirrorQueue = { work, done in
            work()
            done()
        }
        host.stateDirectory = directory
        let prunes = Recorder<RebasedMirrorCleanup.Request>()
        self.prunes = prunes
        host.mirrorPrune = { request in
            prunes.append(request)
            return RebasedMirrorCleanup.prune(.init(stateDirectory: request.stateDirectory, inUse: request.inUse,
                                                    maxAgeDays: request.maxAgeDays, dryRun: true))
        }
        host.now = { [unowned self] in clock }
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

    func testOnCloseRunsOnceAcrossEveryReleasePath() throws {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        _ = window("frame", number: 7)
        for path in ["overlay", "session", "pane", "paneTeardown", "sessionTeardown", "frameClosed", "frameThenSession", "quit"] {
            let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp"))
            let pane: OverlayPane? = path.hasPrefix("pane") ? .left : nil
            if pane != nil { store.toggleSplit(session.id) }
            var commands: [RebasedOnClose] = []
            host.runOnClose = { commands.append($0) }
            host.environment = { _, _ in ["REVIEW_ENV": "before"] }
            let opened = try host.openOverlay(in: store, session: session.id, cwd: "/tmp", sizePercent: nil,
                                              pane: pane, onClose: "/bin/flush --final").get()
            session.currentCwd = "/changed"
            host.environment = { _, _ in ["REVIEW_ENV": "after"] }
            host.setSlotVisible(true, session: session.id)
            host.handle(event: "ready", payload: "")
            host.handle(event: "frameOpened", payload: "\(project)\t7")
            switch path {
            case "overlay": store.closeOverlay(session.id)
            case "session": store.closeSession(session.id)
            case "pane": store.closePaneOverlay(session.id, pane: .left)
            case "paneTeardown": session.teardownPaneOverlay(.left)
            case "sessionTeardown": session.teardownOverlaySlot()
            case "frameClosed": host.handle(event: "frameClosed", payload: project)
            case "frameThenSession":
                host.handle(event: "frameClosed", payload: project)
                store.closeSession(session.id)
            default: host.releaseAllBeforeQuit()
            }
            XCTAssertEqual(commands.count, 1, path)
            host.releaseAllBeforeQuit()
            XCTAssertEqual(commands.count, 1, path)
            XCTAssertEqual(commands.first?.command, "/bin/flush --final")
            XCTAssertEqual(commands.first?.cwd, "/tmp")
            XCTAssertEqual(commands.first?.environment, ["REVIEW_ENV": "before"])
            if path != "quit" { XCTAssertNil(session.rebasedPlacement, path) }
            _ = opened
        }
    }

    func testOnCloseWithoutCwdCapturesALocalDirectoryOrHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        var commands: [RebasedOnClose] = []
        host.runOnClose = { commands.append($0) }
        for path in [root.path, root.appendingPathComponent("missing").path, file.path] {
            first.currentCwd = path
            let opened = try host.openOverlay(in: store, session: first.id, cwd: nil, sizePercent: nil, onClose: "true").get()
            first.currentCwd = "/changed"
            XCTAssertTrue(store.closeRebasedOverlay(first.id, id: opened.overlay))
            XCTAssertEqual(commands.last?.cwd, path == root.path ? root.path : NSHomeDirectory())
        }
        XCTAssertEqual(commands.count, 3)
    }

    func testQuitRunsCallbacksWithoutCallingTheIDE() throws {
        _ = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, onClose: "first").get()
        _ = try host.openOverlay(in: store, session: second.id, cwd: project, sizePercent: nil, onClose: "second").get()
        host.setSlotVisible(true, session: first.id)
        host.setSlotVisible(true, session: second.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        let calls = runtime.calls, frameChanges = frames.log
        var commands: [RebasedOnClose] = []
        host.runOnClose = { command in
            XCTAssertEqual(self.runtime.calls, calls)
            commands.append(command)
        }
        host.releaseAllBeforeQuit()
        host.releaseAllBeforeQuit()
        XCTAssertEqual(runtime.calls, calls)
        XCTAssertEqual(frames.log, frameChanges)
        XCTAssertEqual(Set(commands.map(\.command)), ["first", "second"])
        XCTAssertEqual(commands.count, 2)
    }

    func testARefusedOnCloseOpenPreservesTheViewAndCapturedCallback() throws {
        var commands: [RebasedOnClose] = []
        var captures = 0
        host.runOnClose = { commands.append($0) }
        host.environment = { _, _ in captures += 1; return ["REVIEW_ENV": "original"] }
        let opened = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil,
                                          view: .file(path: "/tmp/original", line: 1), onClose: "/bin/original").get()
        let before = first.rebasedOverlay
        XCTAssertEqual(refusal(host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil,
                                                view: .file(path: "/tmp/replacement", line: 9), onClose: "/bin/replacement")),
                       "a Rebased overlay is already open in this session; --on-close needs a new one")
        XCTAssertEqual(first.rebasedOverlay, before)
        XCTAssertEqual(captures, 1)
        XCTAssertTrue(commands.isEmpty)
        store.closeRebasedOverlay(first.id, id: opened.overlay)
        XCTAssertEqual(commands.map(\.command), ["/bin/original"])
    }

    func testHideHandBackPromotionAndSwapNeverRunOnClose() throws {
        var commands: [RebasedOnClose] = []
        host.runOnClose = { commands.append($0) }
        first.surface = MovablePane()
        store.toggleSplit(first.id)
        first.splitSurface = MovablePane()
        let opened = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil,
                                          pane: .right, onClose: "/bin/flush").get()
        host.setSlotVisible(true, session: first.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        store.setRebasedHidden(first.id, id: opened.overlay, true)
        host.hide(overlay: opened.overlay)
        store.setRebasedHidden(first.id, id: opened.overlay, false)
        host.show(overlay: opened.overlay)
        open(second)
        store.closeOverlay(second.id)
        store.closePrimaryPane(first.id)
        XCTAssertEqual(first.rebasedPlacement?.pane, .left)
        store.toggleSplit(first.id)
        first.splitSurface = MovablePane()
        XCTAssertNil(store.swapPanes(first.id))
        XCTAssertEqual(first.rebasedPlacement?.pane, .right)
        XCTAssertTrue(commands.isEmpty)
        store.closePaneOverlay(first.id, pane: .right)
        XCTAssertEqual(commands.count, 1)
    }

    func testSoftCloseRunsOnCloseOnlyAtFinalizeAndUndoKeepsItArmed() throws {
        var commands: [RebasedOnClose] = []
        host.runOnClose = { commands.append($0) }
        let opened = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, onClose: "/bin/flush").get()
        XCTAssertTrue(store.softCloseSession(first.id, grace: 60))
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(store.undoPendingClose())
        store.finalizeAllPendingCloses()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(first.rebasedOverlay?.id, opened.overlay)
        XCTAssertTrue(store.softCloseSession(first.id, grace: 60))
        store.finalizeAllPendingCloses()
        host.releaseAllBeforeQuit()
        XCTAssertEqual(commands.count, 1)
    }

    func testQuitDrainsStartingHoldersBeforeTheJVMIsReady() throws {
        var commands: [RebasedOnClose] = []
        host.runOnClose = { commands.append($0) }
        _ = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, onClose: "/bin/first").get()
        _ = try host.openOverlay(in: store, session: second.id, cwd: otherProject, sizePercent: nil, onClose: "/bin/second").get()
        XCTAssertEqual(host.jvm, .starting)
        host.releaseAllBeforeQuit()
        host.releaseAllBeforeQuit()
        XCTAssertEqual(Set(commands.map(\.command)), ["/bin/first", "/bin/second"])
        XCTAssertEqual(commands.count, 2)
    }

    func testAFailedStartStillRunsOnCloseExactlyOnce() throws {
        runtime.startError = RebasedRuntimeError.failed("missing app")
        var commands: [RebasedOnClose] = []
        host.runOnClose = { commands.append($0) }
        _ = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, onClose: "/bin/flush").get()
        XCTAssertEqual(first.rebasedOverlay?.state, .failed("missing app"))
        store.closeOverlay(first.id)
        host.releaseAllBeforeQuit()
        XCTAssertEqual(commands.count, 1)
    }

    func testQuitDrainsAFailedHolderWithoutARunningJVM() throws {
        runtime.startError = RebasedRuntimeError.failed("missing app")
        var commands: [RebasedOnClose] = []
        host.runOnClose = { commands.append($0) }
        _ = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, onClose: "/bin/flush").get()
        host.releaseAllBeforeQuit()
        host.releaseAllBeforeQuit()
        XCTAssertEqual(commands.count, 1)
    }

    func testAStartingViewWaitsForItsVisibleFrameBeforeArmingTheDeadline() throws {
        let opened = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil,
                                          view: .file(path: "/tmp/a.kt", line: 3)).get()
        let request = try XCTUnwrap(opened.request)
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .queued)
        XCTAssertFalse(timers.contains { $0.delay == RebasedHost.viewDeadline })
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .queued)
        XCTAssertFalse(runtime.calls.contains { $0.hasPrefix("openFile ") })
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .sent)
        XCTAssertEqual(runtime.calls.last, "openFile \(request)\t3\t/tmp/a.kt\t\(project)")
        XCTAssertEqual(timers.filter { $0.delay == RebasedHost.viewDeadline }.count, 1)
    }

    func testAHiddenViewStaysQueuedUntilTheHolderShowsAgain() throws {
        startAndShow(first)
        let id = try XCTUnwrap(first.rebasedOverlay?.id)
        XCTAssertTrue(store.setRebasedHidden(first.id, id: id, true))
        host.hide(overlay: id)
        let request = host.requestView(overlay: id, view: .file(path: "/tmp/a", line: 0))
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .queued)
        XCTAssertFalse(timers.contains { $0.delay == RebasedHost.viewDeadline })
        XCTAssertTrue(store.setRebasedHidden(first.id, id: id, false))
        host.show(overlay: id)
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .sent)
        host.handle(event: "viewOpened", payload: request + "\t/tmp/a")
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .opened)
        XCTAssertEqual(first.rebasedOverlay?.view?.detail, "/tmp/a")
    }

    func testViewEventsMatchOnlyTheCurrentRequestAndTheDeadlineLeavesTheJVMRunning() throws {
        startAndShow(first)
        let id = try XCTUnwrap(first.rebasedOverlay?.id)
        let old = host.requestView(overlay: id, view: .file(path: "/tmp/old", line: 0))
        let current = host.requestView(overlay: id, view: .file(path: "/tmp/current", line: 0))
        XCTAssertNotEqual(old, current)
        host.handle(event: "viewOpened", payload: old + "\told")
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .sent)
        XCTAssertNil(first.rebasedOverlay?.view?.detail)
        host.handle(event: "viewOpened", payload: current + "\t/tmp/current")
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .opened)
        let failed = host.requestView(overlay: id, view: .file(path: "/missing", line: 0))
        host.handle(event: "viewFailed", payload: failed + "\tfile not found")
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .failed)
        XCTAssertEqual(first.rebasedOverlay?.view?.detail, "file not found")
        let timed = host.requestView(overlay: id, view: .file(path: "/slow", line: 0))
        fire(RebasedHost.viewDeadline)
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .failed)
        XCTAssertEqual(first.rebasedOverlay?.view?.detail, "view did not open within 60 s")
        XCTAssertEqual(host.jvm, .running)
        host.handle(event: "viewOpened", payload: timed + "\ttoo late")
        XCTAssertEqual(first.rebasedOverlay?.view?.state, .failed)
    }

    func testAPaneViewSendsThePaneAndWorkingTreeFields() throws {
        store.toggleSplit(first.id)
        let opened = try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil,
                                          view: .diff(range, workingTree: true), pane: .left).get()
        host.setSlotVisible(true, session: first.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        XCTAssertEqual(runtime.calls.last, "diff \(try XCTUnwrap(opened.request))\tmain\tHEAD\t1\t1\tpane\t\(project)")
    }

    func testRemoteShowRefreshesBeforeSendingItsView() throws {
        let (remote, calls) = try remoteRow(refresh: .success(mirrored))
        let opened = try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get()
        host.setSlotVisible(true, session: remote.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        var pending: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.onMirrorQueue = { work, done in pending.append((work, done)) }
        let request = host.requestView(overlay: opened.overlay, view: .diff(range, workingTree: false))
        XCTAssertEqual(remote.rebasedOverlay?.view?.state, .queued)
        XCTAssertEqual(calls.paths.count, 1)
        XCTAssertFalse(runtime.calls.contains { $0.hasPrefix("diff " + request) })
        let (work, done) = try XCTUnwrap(pending.first)
        work()
        done()
        XCTAssertEqual(calls.paths.count, 2)
        XCTAssertEqual(remote.rebasedOverlay?.view?.state, .sent)
        XCTAssertEqual(runtime.calls.last, "diff \(request)\tmain\tHEAD\t1\t0\tsession\t\(project)")
    }

    func testAFailedRemoteRefreshFailsTheViewWithoutSendingIt() throws {
        let (remote, _) = try remoteRow(refresh: .success(mirrored))
        let opened = try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get()
        host.setSlotVisible(true, session: remote.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        host.mirrorRefresh = { _, _ in .failure(.init(message: "offline")) }
        let request = host.requestView(overlay: opened.overlay, view: .diff(range, workingTree: false))
        XCTAssertEqual(remote.rebasedOverlay?.view?.state, .failed)
        XCTAssertEqual(remote.rebasedOverlay?.view?.detail, "offline")
        XCTAssertEqual(remote.rebasedOverlay?.state, .shown)
        XCTAssertFalse(runtime.calls.contains { $0.hasPrefix("diff " + request) })
    }

    func testPortLookupRunsOffMainWithBackoffAndReportsTheFirstPort() {
        startAndShow(first)
        runtime.answers["port"] = ["", "", "", "", "63342"]
        var workers = 0
        host.offMain = { work, done in workers += 1; work(); done() }
        for delay in [0.5, 1.0, 2.0, 4.0, 4.0] { fire(delay) }
        XCTAssertEqual(workers, 5)
        XCTAssertEqual(host.status.port, 63342)
        fire(4)
        XCTAssertEqual(workers, 5)
    }

    func testPortLookupStopsAtItsDeadlineAndAnotherFrameRestartsIt() {
        startAndShow(first)
        fire(0.5)
        let before = runtime.calls.filter { $0 == "port " }.count
        clock += 30
        fire(30)
        fire(1)
        XCTAssertEqual(runtime.calls.filter { $0 == "port " }.count, before)
        XCTAssertNil(host.status.port)
        runtime.answers["port"] = ["63343"]
        host.handle(event: "frameOpened", payload: "\(project)\t7")
        fire(0.5)
        XCTAssertEqual(host.status.port, 63343)
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
        host.onMirrorQueue = { work, done in pending.append((work, done)) }
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
    private var diffCall: String {
        let request = store.workspaces.flatMap(\.sessions).compactMap { $0.rebasedPlacement?.overlay.view?.id }.first ?? "unissued"
        return "diff \(request)\tmain\tHEAD\t1\t0\tsession\t\(project)"
    }

    func testADiffOpensOnceTheFrameIsShown() {
        let overlay = RebasedOverlay(project: project, diff: range, view: RebasedViewRequest(view: .diff(range, workingTree: false)))
        XCTAssertNil(store.openRebasedOverlay(first.id, overlay: overlay, sizePercent: nil))
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
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, view: .diff(range, workingTree: false)).get())
        XCTAssertEqual(runtime.calls.last, diffCall)
        XCTAssertEqual(first.rebasedOverlay?.diff, range)
        XCTAssertEqual(state(first), .shown)
    }

    func testADiffWaitsWhileTheSlotIsHidden() {
        startAndShow(first)
        host.setSlotVisible(false, session: first.id)
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil, view: .diff(range, workingTree: false)).get())
        XCTAssertFalse(runtime.calls.contains(diffCall))
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(runtime.calls.last, diffCall)
    }

    func testADiffOnAnotherProjectIsRefusedLikeAnyOpen() {
        startAndShow(first)
        XCTAssertEqual(refusal(host.openOverlay(in: store, session: first.id, cwd: otherProject, sizePercent: nil, view: .diff(range, workingTree: false))),
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
        host.onMirrorQueue = { work, done in pending.append((work, done)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo/sub", sizePercent: nil, view: .diff(range, workingTree: false)).get())
        XCTAssertEqual(remote.rebasedOverlay?.state, .fetching)
        XCTAssertEqual(remote.rebasedOverlay?.source, "p4linux:/home/s/repo/sub")
        XCTAssertEqual(refusal(host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil, view: .diff(range, workingTree: false))),
                       "Rebased is still fetching from p4linux")
        let id = remote.rebasedOverlay?.id
        let requestedView = remote.rebasedOverlay?.view
        XCTAssertEqual(host.requestView(overlay: try XCTUnwrap(id), view: .file(path: "/tmp/a", line: 0)), requestedView?.id)
        XCTAssertEqual(remote.rebasedOverlay?.view, requestedView)
        let (work, done) = try XCTUnwrap(pending.first)
        work()
        done()
        XCTAssertEqual(calls.paths, ["/home/s/repo/sub"])
        XCTAssertEqual(remote.rebasedOverlay, RebasedOverlay(project: project, diff: range, source: "p4linux:/home/s/repo", id: try XCTUnwrap(id), view: requestedView))
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
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil, view: .diff(range, workingTree: false)).get())
        XCTAssertEqual(calls.paths, ["/home/s/repo", "/home/s/repo"])
        XCTAssertEqual(runtime.calls.last, diffCall)
        XCTAssertEqual(refusal(host.openOverlay(in: store, session: remote.id, cwd: "/home/s/other", sizePercent: nil, view: .diff(range, workingTree: false))),
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
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil, view: .diff(range, workingTree: false)).get())
        XCTAssertFalse(runtime.calls.contains(diffCall))
        XCTAssertEqual(remote.rebasedOverlay?.state, .shown)
    }

    func testAnOverlayClosedWhileFetchingStaysClosed() throws {
        let (remote, _) = try remoteRow(refresh: .success(mirrored))
        var pending: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.onMirrorQueue = { work, done in pending.append((work, done)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        store.closeOverlay(remote.id)
        let (work, done) = try XCTUnwrap(pending.first)
        work()
        done()
        XCTAssertNil(remote.rebasedOverlay)
        XCTAssertEqual(runtime.starts, 0)
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
    }

    // MARK: Mirror queue

    private typealias Job = (work: @Sendable () -> Void, done: @MainActor @Sendable () -> Void)

    private func capturedJobs() -> () -> [Job] {
        let jobs = Recorder<Job>()
        host.onMirrorQueue = { work, done in jobs.append((work, done)) }
        return { jobs.items }
    }

    @discardableResult
    private func seedStaleMirror() throws -> URL {
        let hash = directory.appendingPathComponent("rebased/mirrors/p4linux/0a1b2c3d", isDirectory: true)
        let clone = hash.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 30 * 86_400).rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: hash.path)
        return clone
    }

    private func offQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws -> T {
        let result = Recorder<T>()
        let finished = expectation(description: "ran off the main queue")
        let body: @Sendable () -> Void = {
            result.append(work())
            finished.fulfill()
        }
        DispatchQueue.global().async(execute: body)
        await fulfillment(of: [finished], timeout: 10)
        return try XCTUnwrap(result.items.first)
    }

    func testTheIDEStartPrunesAfterPrepareAndBeforeLaunch() {
        host.mirrorMaxAgeDays = { 14 }
        let runtime = runtime!
        let seen = Recorder<String>()
        let record = host.mirrorPrune
        host.mirrorPrune = { request in
            seen.append("prepares \(runtime.prepares) starts \(runtime.starts)")
            return try record(request)
        }
        open(first)
        XCTAssertEqual(seen.items, ["prepares 1 starts 0"])
        XCTAssertEqual(runtime.starts, 1)
        let request = prunes.items.first
        XCTAssertEqual(request?.inUse, [RebasedHost.canonical(project)])
        XCTAssertEqual(request?.maxAgeDays, 14)
        XCTAssertEqual(request?.dryRun, false)
        XCTAssertEqual(request?.stateDirectory, directory)
    }

    func testTheStartDeadlineIsArmedAfterThePrune() throws {
        host.mirrorMaxAgeDays = { 14 }
        let jobs = capturedJobs()
        open(first)
        XCTAssertEqual(runtime.prepares, 1)
        XCTAssertTrue(timers.isEmpty)
        XCTAssertEqual(runtime.starts, 0)
        let job = try XCTUnwrap(jobs().first)
        job.work()
        XCTAssertTrue(timers.isEmpty)
        job.done()
        XCTAssertEqual(timers.map(\.delay), [RebasedHost.readyDeadline])
        XCTAssertEqual(runtime.starts, 1)
    }

    func testAFailedPrepareDoesNotPrune() {
        host.mirrorMaxAgeDays = { 14 }
        runtime.prepareError = RebasedRuntimeError.failed(RebasedStateLock.message)
        open(first)
        XCTAssertEqual(state(first), .failed(RebasedStateLock.message))
        XCTAssertTrue(prunes.items.isEmpty)
        XCTAssertEqual(runtime.starts, 0)
    }

    func testAZeroMaxAgeSkipsTheStartPruneAndLaunches() {
        open(first)
        XCTAssertTrue(prunes.items.isEmpty)
        XCTAssertEqual(runtime.starts, 1)
        XCTAssertEqual(timers.map(\.delay), [RebasedHost.readyDeadline])
    }

    func testTheStartPruneIsSkippedWhileAnotherRowFetches() throws {
        host.mirrorMaxAgeDays = { 14 }
        let (remote, calls) = try remoteRow(refresh: .success(mirrored))
        let jobs = capturedJobs()
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        open(first)
        XCTAssertEqual(jobs().count, 1)
        try XCTUnwrap(jobs().first).work()
        XCTAssertEqual(calls.paths, ["/home/s/repo"])
        XCTAssertTrue(prunes.items.isEmpty)
        XCTAssertEqual(runtime.starts, 1)
    }

    func testARefreshAndAPruneRunOneAfterTheOther() throws {
        host.mirrorMaxAgeDays = { 14 }
        let events = Recorder<String>()
        let (remote, _) = try remoteRow(refresh: .success(mirrored))
        host.mirrorRefresh = { [mirrored] _, _ in
            events.append("refresh")
            return .success(mirrored)
        }
        let record = host.mirrorPrune
        host.mirrorPrune = { request in
            events.append("prune")
            return try record(request)
        }
        host.offMain = { work, done in
            events.append("offMain start")
            work()
            events.append("offMain end")
            done()
        }
        let jobs = capturedJobs()
        open(first)
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        XCTAssertEqual(jobs().count, 2)
        XCTAssertEqual(events.items, ["offMain start", "offMain end"])
        for job in jobs() {
            job.work()
            job.done()
        }
        XCTAssertEqual(events.items, ["offMain start", "offMain end", "prune", "offMain start", "offMain end", "refresh"])
    }

    private func showFrame(of session: Session, project: String) {
        host.setSlotVisible(true, session: session.id)
        host.handle(event: "ready", payload: "")
        _ = window("frame", number: 7)
        host.handle(event: "frameOpened", payload: "\(project)\t7")
    }

    private func reshow(_ session: Session) {
        host.setSlotVisible(false, session: session.id)
        host.setSlotVisible(true, session: session.id)
    }

    func testShowingAMirrorOverlayTouchesItsMarkerAtMostHourly() throws {
        let hash = directory.appendingPathComponent("rebased/mirrors/p4linux/0a1b2c3d", isDirectory: true)
        let clone = hash.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let (remote, _) = try remoteRow(refresh: .success(.init(directory: clone.path, source: "p4linux:/home/s/repo")))
        var now = Date(timeIntervalSince1970: 1_791_000_000)
        host.clock = { now }
        let jobs = capturedJobs()
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        let refresh = try XCTUnwrap(jobs().first)
        refresh.work()
        refresh.done()
        showFrame(of: remote, project: clone.path)
        XCTAssertTrue(host.isShown(in: remote.id))
        XCTAssertEqual(jobs().count, 2)
        try XCTUnwrap(jobs().dropFirst().first).work()
        XCTAssertEqual(RebasedMirrorMarker.read(from: hash), RebasedMirrorMarker(source: "p4linux:/home/s/repo", lastOpened: now))
        now += 59 * 60
        reshow(remote)
        XCTAssertEqual(jobs().count, 2)
        now += 2 * 60
        reshow(remote)
        XCTAssertEqual(jobs().count, 3)
        try XCTUnwrap(jobs().dropFirst(2).first).work()
        XCTAssertEqual(RebasedMirrorMarker.read(from: hash)?.lastOpened, now)
    }

    func testARemoteRowOutsideTheMirrorsDirectoryNeverTouchesAMarker() throws {
        let (remote, _) = try remoteRow(refresh: .success(mirrored))
        let jobs = capturedJobs()
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        let refresh = try XCTUnwrap(jobs().first)
        refresh.work()
        refresh.done()
        XCTAssertNotNil(remote.rebasedOverlay?.source)
        showFrame(of: remote, project: project)
        XCTAssertTrue(host.isShown(in: remote.id))
        XCTAssertEqual(jobs().count, 1)
    }

    func testALocalOverlayNeverTouchesAMarker() {
        let jobs = capturedJobs()
        startAndShow(first)
        XCTAssertTrue(host.isShown(in: first.id))
        XCTAssertTrue(jobs().isEmpty)
    }

    func testTheDefaultMirrorQueueRunsWorkOffMainAndDoneOnMainOneAtATime() async {
        let queue = RebasedHost()
        let events = Recorder<String>()
        let threads = Recorder<String>()
        let firstDone = expectation(description: "first done")
        let secondDone = expectation(description: "second done")
        queue.onMirrorQueue({
            threads.append("work 1 main \(Thread.isMainThread)")
            events.append("1 start")
            usleep(100_000)
            events.append("1 end")
        }, {
            threads.append("done 1 main \(Thread.isMainThread)")
            firstDone.fulfill()
        })
        queue.onMirrorQueue({
            threads.append("work 2 main \(Thread.isMainThread)")
            events.append("2 start")
        }, {
            threads.append("done 2 main \(Thread.isMainThread)")
            secondDone.fulfill()
        })
        await fulfillment(of: [firstDone, secondDone], timeout: 10)
        XCTAssertEqual(events.items, ["1 start", "1 end", "2 start"])
        XCTAssertEqual(Set(threads.items), ["work 1 main false", "work 2 main false", "done 1 main true", "done 2 main true"])
    }

    func testAnUnconfiguredHostNeverPrunes() async throws {
        let clone = try seedStaleMirror()
        let unconfigured = RebasedHost()
        unconfigured.stateDirectory = directory
        let report = try await unconfigured.pruneMirrors(olderThanDays: 1, dryRun: false)
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path))
        let listed = await unconfigured.listMirrors()
        XCTAssertTrue(listed.isEmpty)
    }

    func testAFrameOpenedProjectWithNoOverlayIsInUse() {
        startAndShow(first)
        store.closeOverlay(first.id)
        host.handle(event: "frameClosed", payload: project)
        XCTAssertEqual(host.mirrorsInUse, [RebasedHost.canonical(project)])
    }

    private func localMirrorClone() throws -> String {
        let clone = directory.appendingPathComponent("rebased/mirrors/p4linux/40eee01ce47c7996/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return clone.path
    }

    func testALocalOpenOfAMirrorWaitsForTheMirrorQueueAndCountsAsInUse() throws {
        let clone = try localMirrorClone()
        var jobs: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.onMirrorQueue = { work, done in jobs.append((work, done)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: clone, sizePercent: nil).get())
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(runtime.prepares, 0)
        XCTAssertTrue(host.mirrorsInUse.contains(RebasedHost.canonical(clone)))

        jobs[0].0()
        jobs[0].1()
        XCTAssertEqual(runtime.prepares, 1)
    }

    func testALocalOpenOfAMirrorAPruneRemovedFails() throws {
        let clone = try localMirrorClone()
        var jobs: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.onMirrorQueue = { work, done in jobs.append((work, done)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: clone, sizePercent: nil).get())
        try FileManager.default.removeItem(atPath: clone)

        jobs[0].0()
        jobs[0].1()
        XCTAssertEqual(runtime.prepares, 0)
        XCTAssertEqual(state(first), .failed("Rebased mirror \(clone) was removed by a prune"))
        XCTAssertFalse(host.mirrorsInUse.contains(RebasedHost.canonical(clone)))
    }

    func testADeferredMirrorOpenLeavesTheSessionsNextOverlayAlone() throws {
        let clone = try localMirrorClone()
        var jobs: [(@Sendable () -> Void, @MainActor @Sendable () -> Void)] = []
        host.onMirrorQueue = { work, done in jobs.append((work, done)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: clone, sizePercent: nil).get())
        store.closeOverlay(first.id)
        XCTAssertFalse(host.mirrorsInUse.contains(RebasedHost.canonical(clone)))
        XCTAssertNoThrow(try host.openOverlay(in: store, session: first.id, cwd: project, sizePercent: nil).get())
        try FileManager.default.removeItem(atPath: clone)

        jobs[0].0()
        jobs[0].1()
        XCTAssertEqual(runtime.prepares, 1)
        XCTAssertNotEqual(state(first), .failed("Rebased mirror \(clone) was removed by a prune"))
    }

    func testTheMirrorRefreshHoldsTheStateLock() {
        let directory = directory!
        let mirror = RebasedMirror(host: "p4linux", path: "/home/s/repo")!
        let copy = RebasedMirrorRefresh.Copy(directory: "/tmp", source: "p4linux:/home/s/repo")
        let runs = Recorder<String>()
        let run: @Sendable (RebasedMirror, URL) -> Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure> = { _, _ in
            runs.append("run")
            return .success(copy)
        }
        let locks = Recorder<String>()
        let held = RebasedHost.makeMirrorRefresh(withLock: { url, body in
            locks.append(url.path)
            return body()
        }, run: run)
        XCTAssertEqual(held(mirror, directory), .success(copy))
        XCTAssertEqual(locks.items, [directory.appendingPathComponent("rebased").path])

        let refused = RebasedHost.makeMirrorRefresh(withLock: { _, _ in throw RebasedRuntimeError.failed(RebasedStateLock.message) },
                                                     run: run)
        XCTAssertEqual(refused(mirror, directory), .failure(.init(message: RebasedStateLock.message)))
        XCTAssertEqual(runs.items, ["run"])
    }

    func testTheMirrorPruneFactoryLocksOnlyARealPrune() async throws {
        let clone = try seedStaleMirror()
        let directory = try XCTUnwrap(directory)
        let locks = Recorder<String>()
        let recording: RebasedHost.MirrorLock = { url, body in
            locks.append(url.path)
            return try body()
        }
        let refusing: RebasedHost.MirrorLock = { _, _ in throw RebasedRuntimeError.failed(RebasedStateLock.message) }
        let request: @Sendable (Bool) -> RebasedMirrorCleanup.Request = {
            .init(stateDirectory: directory, inUse: [], maxAgeDays: 1, dryRun: $0)
        }

        let dryRun = RebasedHost.makeMirrorPrune(withLock: recording)
        let dry = try await offQueue { Result { try dryRun(request(true)) } }.get()
        XCTAssertEqual(dry.removed.count, 1)
        XCTAssertTrue(locks.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path))

        let refused = RebasedHost.makeMirrorPrune(withLock: refusing)
        let failure = try await offQueue { Result { try refused(request(false)) } }
        XCTAssertThrowsError(try failure.get()) { error in
            XCTAssertEqual(error as? RebasedRuntimeError, .failed(RebasedStateLock.message))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path))

        let real = RebasedHost.makeMirrorPrune(withLock: recording)
        let pruned = try await offQueue { Result { try real(request(false)) } }.get()
        XCTAssertEqual(pruned.removed.count, 1)
        XCTAssertEqual(locks.items, [directory.appendingPathComponent("rebased").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path))
    }

    func testTheMirrorListFactoryMeasuresAndMarksInUse() async throws {
        let clone = try seedStaleMirror()
        let directory = try XCTUnwrap(directory)
        let list = RebasedHost.makeMirrorList()
        let held = try await offQueue { list(directory, [RebasedMirrorCleanup.projectPath(clone)]) }
        XCTAssertEqual(held.count, 1)
        XCTAssertNotNil(held.first?.bytes)
        XCTAssertEqual(held.first?.inUse, true)
        let free = try await offQueue { list(directory, []) }
        XCTAssertEqual(free.first?.inUse, false)
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
        host.mirrorMaxAgeDays = { 14 }
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

    func testAPreFrameDialogPausesTheDeadlineUntilItCloses() {
        open(first)
        host.handle(event: "ready", payload: "")
        let trust = window("trust", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t")
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(first), .starting)

        trust.close()
        fire(RebasedHost.readyDeadline)
        XCTAssertEqual(state(first), .failed(RebasedHost.deadlineMessage))
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
        XCTAssertEqual(state(first), .starting)
        host.setSlotVisible(true, session: first.id)
        XCTAssertEqual(frames.log.last, "attach trust to host1")
    }
}

final class Recorder<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Item] = []

    func append(_ item: Item) { lock.withLock { stored.append(item) } }

    var items: [Item] { lock.withLock { stored } }
}

final class MirrorCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var mirrors: [RebasedMirror] = []

    func append(_ mirror: RebasedMirror) { lock.withLock { mirrors.append(mirror) } }

    var paths: [String] { lock.withLock { mirrors.map(\.path) } }
}
