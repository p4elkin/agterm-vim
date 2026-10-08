import AppKit
import XCTest
@testable import agterm
import agtermCore

private final class FakeRuntime: RebasedRuntime, @unchecked Sendable {
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
    func call(_ command: String, _ argument: String) -> String {
        calls.append("\(command) \(argument)")
        return "ok"
    }

    var jvmCreated: Bool { created }
}

@MainActor
private final class FakeFrames: RebasedFrames {
    private(set) var log: [String] = []
    var names: [ObjectIdentifier: String] = [:]

    private func name(_ window: NSWindow?) -> String { window.flatMap { names[ObjectIdentifier($0)] } ?? "nil" }
    func adopt(_ frame: NSWindow, in host: NSWindow?) { log.append("adopt \(name(frame)) in \(name(host))") }
    func attach(_ window: NSWindow, to host: NSWindow?) { log.append("attach \(name(window)) to \(name(host))") }
    func detach(_ window: NSWindow) { log.append("detach \(name(window))") }
    func orderOut(_ window: NSWindow) { log.append("orderOut \(name(window))") }
}

@MainActor
final class RebasedHostTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var first: Session!
    private var second: Session!
    private var host: RebasedHost!
    private var runtime: FakeRuntime!
    private var frames: FakeFrames!
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
        runtime = FakeRuntime()
        frames = FakeFrames()
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
}
