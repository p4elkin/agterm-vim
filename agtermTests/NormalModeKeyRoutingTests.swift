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
                                                                      target: .builtin(.toggleSplit))])
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

    /// Add a session to the frontmost store and select it, so the monitor's overlay question has something
    /// to ask. The library's own window supplies the store; the test's `window` only carries first responder.
    private func selectedSession() throws -> (store: AppStore, session: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        store.selectSession(session.id)
        return (store, session)
    }

    /// ⚠️ A program overlay (vifm, an editor, `session.overlay.open`) owns the keyboard, and the mode would
    /// otherwise eat every key before the overlay's pty saw one. The mode SUSPENDS instead of exiting, so the
    /// editor a bind opened hands the user back to the mode on quit.
    func testAProgramOverlaySuspendsTheModeAndReleasesItsKeysWithoutEndingIt() throws {
        try skipUnlessLayoutIsASCIICapable()
        let (store, session) = try selectedSession()
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))

        XCTAssertFalse(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                       "the overlay's program must receive the key")
        XCTAssertTrue(fired.isEmpty, "the bind must not fire behind the overlay")
        XCTAssertTrue(NormalModeController.shared.isActive, "suspending is not exiting")

        store.closeOverlay(session.id)
        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "the very next key after the overlay closes is the mode's again")
        XCTAssertEqual(fired, [.toggleSplit])
    }

    /// A HUD is a passive message panel that takes no keystrokes, so it must leave the mode driving — the
    /// suspension asks `programOverlayActive`, never the raw slot.
    func testAHudDoesNotSuspendTheMode() throws {
        try skipUnlessLayoutIsASCIICapable()
        let (store, session) = try selectedSession()
        XCTAssertTrue(store.openHud(session.id, command: "true", spec: HudSpec(message: "working"),
                                    file: (NSTemporaryDirectory() as NSString).appendingPathComponent("hud-body"),
                                    size: HudPanelSize(widthPercent: 40, heightPercent: 20)))

        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "a HUD covers nothing, so the mode still owns the key")
        XCTAssertEqual(fired, [.toggleSplit])
        XCTAssertTrue(NormalModeController.shared.isActive)
    }

    /// The suspension drops a half-typed sequence like every other way out of the terminal does: the chord
    /// that would have completed it went to the overlay, so re-arming from the first chord is the only
    /// honest state to come back to.
    func testAnOverlayAbandonsAHalfTypedLeader() throws {
        try skipUnlessLayoutIsASCIICapable()
        NormalModeController.shared.rebuild(binds: [NormalModeBind(keybind: [Chord(mods: [], key: "g"),
                                                                            Chord(mods: [], key: "g")],
                                                                  target: .builtin(.toggleSplit))])
        NormalModeController.shared.enter()
        let (store, session) = try selectedSession()

        XCTAssertTrue(runner.handleKeyDown(try keyDown("g", keyCode: 5), in: window), "the first chord arms")
        XCTAssertTrue(NormalModeController.shared.isArmed)

        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))
        XCTAssertFalse(runner.handleKeyDown(try keyDown("g", keyCode: 5), in: window))

        XCTAssertFalse(NormalModeController.shared.isArmed, "the leader must not survive the overlay")
        XCTAssertTrue(NormalModeController.shared.isActive)
        XCTAssertTrue(fired.isEmpty, "the sequence must not complete across the overlay")
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

    /// Build a runner over a keymap file this test owns. `start()` is what parses it into the matcher and the
    /// mode's binds; it also leaves the mode OFF, so a case that needs it on re-enters after starting.
    private func seededRunner(keymap: String) throws -> CustomCommandRunner {
        let configDir = stateDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try keymap.write(to: configDir.appendingPathComponent("keymap.conf"), atomically: true, encoding: .utf8)
        let store = SettingsStore(directory: stateDir)
        var seededSettings = store.load()
        seededSettings.configDirectory = configDir.path
        try store.save(seededSettings)
        return CustomCommandRunner(library: library,
                                   settings: SettingsModel(library: library, settingsStore: store),
                                   performBuiltin: { [weak self] in self?.fired.append($0) },
                                   socketProvider: { "" })
    }

    private func markerLineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    /// A fired command is a detached process, so the only honest assertion is its side effect on disk.
    private func waitForMarkerLines(_ url: URL, count: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if markerLineCount(url) >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return markerLineCount(url) >= count
    }

    private func markerCommandKeymap(marker: URL, extraLines: String = "") -> String {
        """
        command "Marker" echo x >> "\(marker.path)"
        nmap e "Marker"
        \(extraLines)
        """
    }

    func testABareKeyBoundToACustomCommandSpawnsItAndIsConsumed() throws {
        try skipUnlessLayoutIsASCIICapable()
        let marker = stateDir.appendingPathComponent("fired.txt")
        let seeded = try seededRunner(keymap: markerCommandKeymap(marker: marker))
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()

        XCTAssertTrue(seeded.handleKeyDown(try keyDown("e", keyCode: 14), in: window),
                      "a command bind consumes its key like any other bind")
        XCTAssertTrue(waitForMarkerLines(marker, count: 1), "the bound command must actually run")
        XCTAssertTrue(NormalModeController.shared.isActive, "firing a command leaves the mode on")
    }

    /// ⚠️ The mode takes OS key repeats on purpose, so holding `k` skims sessions — but a command target
    /// spawns a process, and inheriting repeats there would stack one per repeat. The guard sits inside the
    /// command case alone and still consumes the key; a built-in bind keeps repeating.
    func testHoldingACommandBindSpawnsOnceWhileAHeldBuiltinStillRepeats() throws {
        try skipUnlessLayoutIsASCIICapable()
        let marker = stateDir.appendingPathComponent("fired.txt")
        let seeded = try seededRunner(keymap: markerCommandKeymap(marker: marker,
                                                                 extraLines: "nmap s toggle_split"))
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()

        XCTAssertTrue(seeded.handleKeyDown(try keyDown("e", keyCode: 14), in: window))
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("e", keyCode: 14, isARepeat: true), in: window),
                      "a repeat on a command bind is still consumed, just not run")
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("e", keyCode: 14, isARepeat: true), in: window))

        XCTAssertTrue(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window))
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("s", keyCode: 1, isARepeat: true), in: window))
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("s", keyCode: 1, isARepeat: true), in: window))
        XCTAssertEqual(fired, [.toggleSplit, .toggleSplit, .toggleSplit],
                       "a built-in target still fires on every OS repeat")

        XCTAssertTrue(waitForMarkerLines(marker, count: 1), "the first press must run the command")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(markerLineCount(marker), 1, "the two OS repeats must not spawn a second process")
    }

    /// The global matcher must keep IGNORING repeats — a held custom-command chord spawns one process, not
    /// one per OS repeat — which is why the guard moved below the normal-mode branch instead of away. A
    /// built-in leader stands in for a custom command so the test fires an action instead of a process.
    func testTheGlobalMatcherStillIgnoresKeyRepeats() throws {
        try skipUnlessLayoutIsASCIICapable()
        // the mode rebuilds off this same (nmap-free) file and stays off, which is the state this path needs.
        let seeded = try seededRunner(keymap: "map ctrl+a>s toggle_split\n")
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
