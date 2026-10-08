import AppKit
import XCTest
@testable import agterm

@MainActor
final class RebasedFrameKeeperTests: XCTestCase {
    private var keeper: RebasedFrameKeeper!
    private var host: NSWindow!
    private var frame: NSWindow!
    private var timers: [@MainActor () -> Void] = []
    private let slot = NSRect(x: 200, y: 200, width: 600, height: 400)

    override func setUp() async throws {
        keeper = RebasedFrameKeeper()
        keeper.after = { [unowned self] _, work in timers.append(work) }
        keeper.slotRect = { [unowned self] _ in slot }
        host = window(NSRect(x: 100, y: 100, width: 900, height: 700), style: [.titled, .resizable])
        frame = window(NSRect(x: 10, y: 10, width: 300, height: 300), style: [.titled, .resizable, .miniaturizable])
        frame.orderFront(nil)
    }

    override func tearDown() async throws {
        host.childWindows?.forEach { host.removeChildWindow($0) }
        frame.orderOut(nil)
        host.orderOut(nil)
    }

    private func window(_ rect: NSRect, style: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func fireTimers() {
        let due = timers
        timers = []
        due.forEach { $0() }
    }

    func testAdoptAttachesFitsAndStaysInvisibleUntilQuiet() {
        keeper.adopt(frame, in: host)
        XCTAssertTrue(frame.parent === host)
        XCTAssertEqual(frame.frame, slot)
        XCTAssertEqual(frame.alphaValue, 0)
        XCTAssertTrue(frame.collectionBehavior.contains(.fullScreenNone))
        fireTimers()
        XCTAssertEqual(frame.alphaValue, 1)
        XCTAssertTrue(keeper.isRevealed(frame))
    }

    func testAnAdoptedFrameIsFlatAndOnlyTheKeeperMovesIt() {
        keeper.adopt(frame, in: host)
        XCTAssertEqual(frame.styleMask, .borderless)
        XCTAssertFalse(frame.hasShadow)
        XCTAssertFalse(frame.isMovable)
        frame.styleMask = [.titled, .resizable]
        fireTimers()
        XCTAssertEqual(frame.styleMask, .borderless)
        XCTAssertEqual(frame.frame, slot)
    }

    func testAnIDEChangeBeforeTheRevealRestartsTheQuietWait() {
        keeper.adopt(frame, in: host)
        frame.setFrame(NSRect(x: 0, y: 0, width: 500, height: 500), display: false)
        XCTAssertEqual(frame.frame, slot)
        XCTAssertEqual(timers.count, 2)
        timers.removeFirst()()
        XCTAssertEqual(frame.alphaValue, 0, "a superseded wait must not reveal")
        fireTimers()
        XCTAssertEqual(frame.alphaValue, 1)
    }

    func testAResizeOrMoveFromOutsideSnapsBackWithoutLooping() {
        keeper.adopt(frame, in: host)
        fireTimers()
        frame.setFrame(NSRect(x: 0, y: 0, width: 520, height: 380), display: false)
        XCTAssertEqual(frame.frame, slot)
        frame.setFrameOrigin(NSPoint(x: 5, y: 5))
        XCTAssertEqual(frame.frame, slot)
        XCTAssertTrue(timers.isEmpty, "a revealed frame does not wait again")
    }

    func testAMinimizeIsUndone() {
        keeper.adopt(frame, in: host)
        host.removeChildWindow(frame)
        frame.setFrame(NSRect(x: 0, y: 0, width: 50, height: 50), display: false)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: frame)
        XCTAssertTrue(frame.parent === host)
        XCTAssertEqual(frame.frame, slot)
    }

    func testADialogIsAttachedAndKeepsItsSize() {
        let dialog = window(NSRect(x: 0, y: 0, width: 320, height: 140), style: [.titled])
        dialog.orderFront(nil)
        defer { dialog.orderOut(nil) }
        let size = dialog.frame.size
        keeper.attach(dialog, to: host)
        XCTAssertTrue(dialog.parent === host)
        XCTAssertEqual(dialog.frame.size, size)
    }

    func testReparentMovesTheFrameToAnotherWindow() {
        keeper.adopt(frame, in: host)
        let other = window(NSRect(x: 300, y: 300, width: 800, height: 600), style: [.titled])
        other.orderFront(nil)
        defer { other.removeChildWindow(frame); other.orderOut(nil) }
        keeper.reparent(frame, to: other)
        XCTAssertTrue(frame.parent === other)
        XCTAssertFalse(host.childWindows?.contains(frame) ?? false)
    }

    func testAClosingHostDetachesTheFrameWithoutClosingIt() {
        host.orderFront(nil)
        keeper.adopt(frame, in: host)
        let frameCloses = expectation(forNotification: NSWindow.willCloseNotification, object: frame)
        frameCloses.isInverted = true
        host.close()
        wait(for: [frameCloses], timeout: 0.1)
        XCTAssertNil(frame.parent)
        XCTAssertFalse(frame.isVisible)
    }

    func testADetachedFrameIsLeftAlone() {
        keeper.adopt(frame, in: host)
        keeper.detach(frame)
        fireTimers()
        XCTAssertEqual(frame.alphaValue, 0, "a superseded reveal must not show a released frame")
        let moved = NSRect(x: 0, y: 0, width: 50, height: 50)
        frame.setFrame(moved, display: false)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: frame)
        XCTAssertNil(frame.parent)
        XCTAssertEqual(frame.frame, moved)
        keeper.adopt(frame, in: host)
        XCTAssertTrue(frame.parent === host)
        XCTAssertEqual(frame.frame, slot)
    }

    func testAClosingHostReleasesTheFrame() {
        host.orderFront(nil)
        keeper.adopt(frame, in: host)
        host.close()
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: frame)
        XCTAssertNil(frame.parent)
    }

    func testAClosedFrameIsForgotten() {
        keeper.adopt(frame, in: host)
        XCTAssertEqual(keeper.keptCount, 1)
        host.removeChildWindow(frame)
        frame.close()
        XCTAssertEqual(keeper.keptCount, 0)
    }
}
