import AppKit
import XCTest
@testable import agterm
import agtermCore

/// The monitor is the whole of normal mode's key ownership: the mode holds no first responder, so what
/// `CustomCommandRunner` consumes and what it hands back IS the mode's behavior. Three focus bugs came from
/// an AppKit view owning the responder instead, so these pin the rules that replaced it — a focused text
/// field or a modal surface ends the mode and keeps its keystroke, Command and reserved monitor chords are
/// never eaten, key repeats drive the mode's binds but not the global matcher's, and the mode cannot be
/// entered with no key window for the monitor to read.
///
/// The last case here is the one exit that is NOT a keystroke: a click in a terminal pane, which
/// `GhosttySurfaceView.mouseDown` has to spell itself because nothing else sees the click.
@MainActor
final class NormalModeKeyRoutingTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var runner: CustomCommandRunner!
    private var window: NSWindow!
    private var windowID: WindowInfo.ID!
    private var fired: [BuiltinAction] = []
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-normal-mode-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            fired = []
            runner = CustomCommandRunner(library: library,
                                         settings: SettingsModel(library: library,
                                                                 settingsStore: SettingsStore(directory: stateDir)),
                                         performBuiltin: { [weak self] in self?.fired.append($0) },
                                         socketProvider: { "" })
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // the monitor fires from an agterm terminal window even with no focused surface, which is the
            // only shape a test can build: a real `GhosttySurfaceView` would need a live libghostty surface.
            windowID = UUID()
            WindowRegistry.shared.register(windowID, window: window)
            NormalModeController.shared.rebuild(binds: [NormalModeBind(keybind: [Chord(mods: [], key: "s")],
                                                                      action: .toggleSplit)])
            NormalModeController.shared.enter()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NormalModeController.shared.exit()
            NormalModeController.shared.rebuild(binds: [])
            WindowRegistry.shared.unregister(windowID)
            windowID = nil
            actions = nil
            window.orderOut(nil)
            window = nil
            runner = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    /// Skip a case whose outcome only holds while the machine's own layout can type ASCII: `chordKey` reads
    /// the live input source, and on a non-Latin layout the chord resolves by physical position instead.
    private func skipUnlessLayoutIsASCIICapable() throws {
        try XCTSkipUnless(KeyboardLayout.isASCIICapable,
                          "needs an ASCII-capable keyboard layout; chord resolution is covered in KeybindTests")
    }

    /// Clicking a pane with the mode on used to leave it stuck: the pill stayed up and every bare key went to
    /// the shell, because the mode holds no first responder and nothing else observes a click. The exit sits
    /// ABOVE `mouseDown`'s surface guard, so an unrealized pane — the only pane a hosted test can build —
    /// still ends the mode.
    func testClickingATerminalPaneEndsTheMode() throws {
        // a zero frame parks `viewDidMoveToWindow` in `pendingSurfaceCreation`, so no libghostty surface and
        // no shell is spawned, exactly as `GhosttySurfaceViewTrackingTests` does it.
        let pane = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        window.contentView?.addSubview(pane)
        defer { pane.removeFromSuperview() }
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        pane.mouseDown(with: click)

        XCTAssertFalse(NormalModeController.shared.isActive, "a click in a pane is leaving the mode")
    }

    private func keyDown(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [],
                         isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isARepeat, keyCode: keyCode
        ))
    }

    /// The palette case: a bound action opened a palette, its search field took focus, and the next keystroke
    /// belongs to that field. Reasserting the mode's ownership here is what left the palette unable to type.
    func testAFocusedTextFieldEndsTheModeAndKeepsItsKeystroke() throws {
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))

        let consumed = runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window)

        XCTAssertFalse(consumed, "the field must receive the key it was focused to receive")
        XCTAssertFalse(NormalModeController.shared.isActive, "typing into a field is leaving the mode")
    }

    /// ⚠️ The monitor runs ahead of `performKeyEquivalent`, so consuming ⌘Q would trap the user in the mode.
    func testCommandChordsPassThroughToTheMenuBar() throws {
        let consumed = runner.handleKeyDown(try keyDown("q", keyCode: 12, flags: .command), in: window)

        XCTAssertFalse(consumed, "⌘Q must still reach the menu bar")
        XCTAssertTrue(NormalModeController.shared.isActive, "a menu command does not end the mode")
    }

    func testAKeyNoBindMatchesIsSwallowedRatherThanSentToTheTerminal() throws {
        try skipUnlessLayoutIsASCIICapable()

        XCTAssertTrue(runner.handleKeyDown(try keyDown("z", keyCode: 6), in: window))
        XCTAssertTrue(NormalModeController.shared.isActive, "an unmatched key stays in the mode")
        XCTAssertTrue(fired.isEmpty)
    }

    func testABoundKeyFiresItsActionAndIsConsumed() throws {
        try skipUnlessLayoutIsASCIICapable()

        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window))
        XCTAssertEqual(fired, [.toggleSplit])
        XCTAssertTrue(NormalModeController.shared.isActive, "a fired bind leaves the mode on for the next key")
    }

    func testTheExitKeyLeavesTheModeAndIsConsumed() throws {
        try skipUnlessLayoutIsASCIICapable()

        XCTAssertTrue(runner.handleKeyDown(try keyDown("i", keyCode: 34), in: window),
                      "the exit key itself must not reach the terminal")
        XCTAssertFalse(NormalModeController.shared.isActive)
    }

    /// Holding a bare key is the mode's headline move — `k` held down walks back through sessions — so the
    /// repeat guard the custom-command path keeps must not sit in front of the mode.
    func testAHeldBoundKeyRepeatsItsAction() throws {
        try skipUnlessLayoutIsASCIICapable()

        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window))
        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1, isARepeat: true), in: window))
        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1, isARepeat: true), in: window))

        XCTAssertEqual(fired, [.toggleSplit, .toggleSplit, .toggleSplit],
                       "each OS repeat drives the bind again")
    }

    /// ⚠️ ctrl+tab and ctrl+1/2 belong to `SessionSwitcher`/`PaneShortcuts`, whose monitors run whatever the
    /// mode is and whose order among the four `.keyDown` monitors is not controlled. `nmap` rejects them for
    /// exactly that reason, so eating one here would only make registration order decide whether they work.
    func testReservedMonitorChordsPassThroughToTheirOwnMonitors() throws {
        try skipUnlessLayoutIsASCIICapable()

        XCTAssertFalse(runner.handleKeyDown(try keyDown("\t", keyCode: 48, flags: .control), in: window),
                       "⌃Tab belongs to the session switcher")
        XCTAssertFalse(runner.handleKeyDown(try keyDown("1", keyCode: 18, flags: .control), in: window),
                       "⌃1 belongs to the pane shortcuts")
        XCTAssertFalse(runner.handleKeyDown(try keyDown("2", keyCode: 19, flags: .control), in: window),
                       "⌃2 belongs to the pane shortcuts")
        XCTAssertTrue(NormalModeController.shared.isActive, "passing one through does not end the mode")
        XCTAssertTrue(fired.isEmpty)
    }

    /// The dashboard, terminal zoom and a pending picker own the keyboard the way a focused text field does,
    /// and they need the arrows and Return the mode swallows. An `nmap dashboard` bind opens one with the
    /// mode still on, so the gate that blocks ENTRY has to be re-read on the way in as well.
    func testAModalSurfaceEndsTheModeAndKeepsItsKeystroke() throws {
        try skipUnlessLayoutIsASCIICapable()
        let activeWindow = try XCTUnwrap(library.activeWindowID)
        let dashboard = DashboardController()
        dashboard.open(members: [DashboardMember(session: UUID(), surface: .primary)])
        DashboardControllerRegistry.shared.register(activeWindow, controller: dashboard)
        defer { DashboardControllerRegistry.shared.unregister(activeWindow) }

        let consumed = runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window)

        XCTAssertFalse(consumed, "the dashboard must receive the key")
        XCTAssertFalse(NormalModeController.shared.isActive, "a modal taking over ends the mode")
        XCTAssertTrue(fired.isEmpty, "the bind must not fire behind the dashboard either")
    }

    /// The mode is a filter inside a monitor that reads `NSApp.keyWindow`; with none it sees nothing. So
    /// arming it there would show the pill and report `window.list normalMode: true` over a mode no
    /// keystroke can reach — `mode on` from a script while another app is frontmost is the real case.
    func testEnteringIsRefusedWithNoKeyWindow() throws {
        NormalModeController.shared.exit()
        // a property, not a local: `AppActions` has an `isolated deinit`, and releasing one inside a test
        // body over-releases and takes the host down. `tearDown` is where every other suite drops it too.
        actions = AppActions(library: library)

        actions.keyWindowProvider = { nil }
        actions.enterNormalMode()
        XCTAssertFalse(NormalModeController.shared.isActive, "no key window, no mode")

        actions.keyWindowProvider = { [window] in window }
        actions.enterNormalMode()
        XCTAssertTrue(NormalModeController.shared.isActive, "the same call enters with a key window")
    }

    /// The global matcher must keep IGNORING repeats — a held custom-command chord spawns one process, not
    /// one per OS repeat — which is why the guard moved below the normal-mode branch instead of away. A
    /// built-in leader stands in for a custom command so the test fires an action instead of a process.
    func testTheGlobalMatcherStillIgnoresKeyRepeats() throws {
        try skipUnlessLayoutIsASCIICapable()
        let configDir = stateDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "map ctrl+a>s toggle_split\n".write(to: configDir.appendingPathComponent("keymap.conf"),
                                                atomically: true, encoding: .utf8)
        let store = SettingsStore(directory: stateDir)
        var seededSettings = store.load()
        seededSettings.configDirectory = configDir.path
        try store.save(seededSettings)
        let seeded = CustomCommandRunner(library: library,
                                         settings: SettingsModel(library: library, settingsStore: store),
                                         performBuiltin: { [weak self] in self?.fired.append($0) },
                                         socketProvider: { "" })
        // `start()` is what builds the matcher from the keymap; it also rebuilds normal mode off the same
        // (nmap-free) file, leaving the mode off, which is the state this path needs.
        seeded.start()
        defer { seeded.stop() }

        XCTAssertFalse(seeded.handleKeyDown(try keyDown("a", keyCode: 0, flags: .control, isARepeat: true),
                                            in: window),
                       "a held leader chord must not arm the matcher")
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("a", keyCode: 0, flags: .control), in: window),
                      "the same chord pressed once arms it")
        XCTAssertTrue(fired.isEmpty, "arming fires nothing on its own")
    }
}
