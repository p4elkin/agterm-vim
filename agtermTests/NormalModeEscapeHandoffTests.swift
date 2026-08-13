import AppKit
import XCTest
@testable import agterm
import agtermCore

/// The Esc handoff is only real if the BYTE lands in the pty. A test that watched `escapeSender` being called
/// would pass just as happily over a keycode libghostty encodes to nothing, so this one drives the whole path
/// — an Esc key event into `CustomCommandRunner`, the real sender, a REALIZED surface — and reads the byte
/// back off the screen. The pane's tty is in canonical mode with `ECHOCTL`, so it echoes an ESC as `^[`.
///
/// The rest of the routing rules (Esc on an armed leader sends nothing, `i` sends nothing) need no pty and
/// live in `NormalModeKeyRoutingTests`.
@MainActor
final class NormalModeEscapeHandoffTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var runner: CustomCommandRunner!
    private var window: NSWindow!
    private var windowID: WindowInfo.ID!
    private var pane: GhosttySurfaceView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-esc-handoff-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            runner = CustomCommandRunner(library: library,
                                        settings: SettingsModel(library: library,
                                                                settingsStore: SettingsStore(directory: stateDir)),
                                        actions: AppActions(library: library),
                                        socketProvider: { "" })
            // these tests drive Escape alone; a dispatched built-in stays inert, as it was before the hub
            // replaced the injected closure.
            runner.builtinPerformer = { _, _ in }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windowID = UUID()
            WindowRegistry.shared.register(windowID, window: window)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NormalModeController.shared.exit()
            // frees the libghostty surface, which is what ends the spawned command
            pane?.destroySurface()
            pane?.removeFromSuperview()
            pane = nil
            WindowRegistry.shared.unregister(windowID)
            windowID = nil
            window.orderOut(nil)
            window = nil
            runner = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// A pane running `cat -v`, realized and focused in the test's window. Unlike every other hosted
    /// normal-mode test this one needs a live libghostty surface, so the frame is real and the wait is for the
    /// spawned process to exist.
    private func realizedPane() throws -> GhosttySurfaceView {
        let pane = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "cat -v")
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView?.addSubview(pane)
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertTrue(waitUntil { pane.foregroundPid() != nil },
                      "the pane must realize a surface and spawn its command")
        XCTAssertTrue(window.makeFirstResponder(pane))
        return pane
    }

    private func screen() -> String { pane.readScreenText(all: false, lines: nil) ?? "" }

    func testEscapeLeavingTheModeDeliversAnEscapeByteToThePty() throws {
        pane = try realizedPane()
        NormalModeController.shared.enter()
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
            keyCode: InterruptKeystroke.escapeKeyCode
        ))

        XCTAssertTrue(runner.handleKeyDown(escape, in: window),
                      "the raw key event stays consumed; the handoff is a synthesized keypress")

        XCTAssertFalse(NormalModeController.shared.isActive)
        XCTAssertTrue(waitUntil { self.screen().contains("^[") },
                      "the pty must receive an ESC byte; the tty echoes it as ^[. screen: \(screen())")
    }
}
