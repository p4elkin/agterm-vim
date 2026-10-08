import AppKit
import XCTest
@testable import agterm
import agtermCore

/// The app-wide key monitors that do not check the key window leave an IDE window's keys alone.
@MainActor
final class RebasedKeyPassThroughTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!

    override func setUp() async throws {
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-rebased-keys-\(UUID().uuidString)")
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
    }

    override func tearDown() async throws {
        RebasedHost.shared.isIDEKeyWindowOverride = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }

    private func consumed(ide: Bool, _ handle: () throws -> Bool) rethrows -> Bool {
        RebasedHost.shared.isIDEKeyWindowOverride = ide
        return try handle()
    }

    func testControlTabReachesTheIDE() throws {
        let switcher = SessionSwitcher(library: library, canSwitch: { false })
        let event = try key("\t", keyCode: 48, flags: .control)
        XCTAssertFalse(try consumed(ide: true) { switcher.handleKeyDown(event) })
        XCTAssertTrue(try consumed(ide: false) { switcher.handleKeyDown(event) })
    }

    func testControlOneReachesTheIDE() throws {
        let shortcuts = PaneShortcuts(library: library, actions: actions)
        let event = try key("1", keyCode: 18, flags: .control)
        XCTAssertFalse(try consumed(ide: true) { shortcuts.handleKeyDown(event) })
        XCTAssertTrue(try consumed(ide: false) { shortcuts.handleKeyDown(event) })
    }

    func testCommandZReachesTheIDEDuringAPendingClose() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = store.addWorkspace(name: "work")
        _ = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let closing = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", select: false))
        XCTAssertTrue(store.softCloseSession(closing.id, grace: 60))
        XCTAssertNotNil(store.pendingCloseSummary)
        let shortcut = UndoCloseShortcut(actions: actions)
        let event = try key("z", keyCode: 6, flags: .command)
        XCTAssertFalse(try consumed(ide: true) { shortcut.handleKeyDown(event) })
        XCTAssertTrue(try consumed(ide: false) { shortcut.handleKeyDown(event) })
    }

    private final class RecordingWindow: NSWindow {
        var received: [NSEvent] = []
        override func sendEvent(_ event: NSEvent) { received.append(event) }
    }

    func testTheRouterConsumesIDEKeysAndPassesTheRest() throws {
        let host = RebasedHost()
        let ide = RecordingWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        ide.isReleasedWhenClosed = false
        host.keyWindow = { ide }
        host.isIDEKeyWindowOverride = true
        host.keymap = { parseKeymap("map ctrl+shift+r rebased_toggle").keymap }
        var toggles = 0
        host.toggle = { _ in toggles += 1 }
        let handler = RebasedHost.monitor(host)
        let find = try key("f", keyCode: 3, flags: .command)
        XCTAssertNil(handler(find), "an IDE key is consumed, so agterm's menu never sees it")
        XCTAssertEqual(ide.received, [find])
        XCTAssertNil(handler(try key("r", keyCode: 15, flags: [.control, .shift])))
        XCTAssertEqual(toggles, 1)
        XCTAssertNotNil(handler(try key("q", keyCode: 12, flags: .command)))
        XCTAssertEqual(ide.received, [find], "the toggle chord and agterm's chords never reach the IDE")
        host.isIDEKeyWindowOverride = false
        XCTAssertNotNil(handler(find))
        XCTAssertNotNil(RebasedHost.monitor(nil)(find))
    }
}
