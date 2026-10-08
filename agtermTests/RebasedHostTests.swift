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

    func testAQueuedDialogOfAReleasedOverlayNeverReplays() {
        startAndShow(first)
        host.setSlotVisible(false, session: first.id)
        _ = window("dialogA", number: 9)
        host.handle(event: "windowOpened", payload: "9\tdialog\t\(project)")
        store.closeOverlay(first.id)
        open(first, project: otherProject)
        _ = window("frameB", number: 8)
        host.handle(event: "frameOpened", payload: "\(otherProject)\t8")
        XCTAssertEqual(frames.log.last, "adopt frameB in host1")
        XCTAssertFalse(frames.log.contains("attach dialogA to host1"))
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
}
