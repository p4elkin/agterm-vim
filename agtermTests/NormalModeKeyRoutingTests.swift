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
///
/// ⚠️ These cases carry NO ASCII-layout skip, unlike `UndoCloseShortcutTests`. Every key code they
/// synthesize is a `latinKey(forKeyCode:)` table position typing the letter its bind is spelled with
/// (0→a, 1→s, 3→f, 5→g, 6→z, 12→q, 14→e, 15→r, 17→t, 18→1, 19→2, 34→i, 46→m) or a named key, so a layout
/// that cannot type ASCII resolves every one of them by physical position to exactly the same chord.
/// Skipping there hid two thirds of this suite — the whole overlay handover included — behind whichever
/// input source happened to be selected, on the one gate `.claude/rules/fork-rebase.md` names for
/// `handleKeyDown`.
@MainActor
final class NormalModeKeyRoutingTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var runner: CustomCommandRunner!
    private var window: NSWindow!
    private var windowID: WindowInfo.ID!
    private var fired: [BuiltinAction] = []
    private var actions: AppActions!
    /// Every pane the mode handed an Escape to, in order. The send itself needs a realized libghostty surface
    /// no hosted test can build, so `escapeSender` is what these read.
    private var escapeTargets: [GhosttySurfaceView] = []

    /// Records `toggleFullScreen` instead of performing it: the real call opens a Space and animates, which
    /// a unit test must not do to the machine running it.
    private final class RecordingWindow: NSWindow {
        var toggleCount = 0
        override func toggleFullScreen(_ sender: Any?) { toggleCount += 1 }
    }

    /// Stands in for `AppActions.perform`: the runner only dispatches the action, and `normal_mode` entering
    /// the mode is what resets the handover so the keyboard comes back.
    private func record(_ action: BuiltinAction) {
        fired.append(action)
        if action == .normalMode { NormalModeController.shared.enter() }
    }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-normal-mode-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            fired = []
            escapeTargets = []
            runner = CustomCommandRunner(library: library,
                                         settings: SettingsModel(library: library,
                                                                 settingsStore: SettingsStore(directory: stateDir)),
                                         performBuiltin: { [weak self] in self?.record($0) },
                                         socketProvider: { "" })
            runner.escapeSender = { [weak self] pane in self?.escapeTargets.append(pane) }
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
            escapeTargets = []
            window.orderOut(nil)
            window = nil
            runner = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
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
        XCTAssertTrue(runner.handleKeyDown(try keyDown("z", keyCode: 6), in: window))
        XCTAssertTrue(NormalModeController.shared.isActive, "an unmatched key stays in the mode")
        XCTAssertTrue(fired.isEmpty)
    }

    func testABoundKeyFiresItsActionAndIsConsumed() throws {
        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window))
        XCTAssertEqual(fired, [.toggleSplit])
        XCTAssertTrue(NormalModeController.shared.isActive, "a fired bind leaves the mode on for the next key")
    }

    func testTheExitKeyLeavesTheModeAndIsConsumed() throws {
        XCTAssertTrue(runner.handleKeyDown(try keyDown("i", keyCode: 34), in: window),
                      "the exit key itself must not reach the terminal")
        XCTAssertFalse(NormalModeController.shared.isActive)
        XCTAssertTrue(escapeTargets.isEmpty, "`i` means insert at both layers, so it hands nothing down")
    }

    /// A pane focused in the test's window. A zero frame parks `viewDidMoveToWindow` in
    /// `pendingSurfaceCreation`, so no libghostty surface and no shell is spawned.
    private func focusedPane() throws -> GhosttySurfaceView {
        let pane = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        window.contentView?.addSubview(pane)
        XCTAssertTrue(window.makeFirstResponder(pane))
        return pane
    }

    private func escapeKey() throws -> NSEvent {
        try keyDown("\u{1b}", keyCode: InterruptKeystroke.escapeKeyCode)
    }

    /// Esc leaving the mode is a handoff, not just an exit: the pane's program (vim, shell vi-mode, Claude
    /// Code's vim mode) enters ITS normal mode from the same press.
    func testEscapeLeavesTheModeAndHandsAnEscapeDownToThePane() throws {
        let pane = try focusedPane()
        defer { pane.removeFromSuperview() }

        XCTAssertTrue(runner.handleKeyDown(try escapeKey(), in: window),
                      "the raw key event stays consumed; the handoff is a synthesized keypress")

        XCTAssertFalse(NormalModeController.shared.isActive)
        XCTAssertEqual(escapeTargets.count, 1, "exactly one Escape")
        XCTAssertTrue(escapeTargets.first === pane, "it goes to the pane the keystroke came from")
    }

    /// ⚠️ Esc on an armed leader abandons the sequence and STAYS in the mode, so it must send nothing: an
    /// Escape delivered here reaches the shell from behind a mode that is still swallowing every key.
    func testEscapeAbandoningAHalfTypedLeaderSendsNothingAndStaysInTheMode() throws {
        NormalModeController.shared.rebuild(binds: [NormalModeBind(keybind: [Chord(mods: [], key: "g"),
                                                                            Chord(mods: [], key: "g")],
                                                                  target: .builtin(.toggleSplit))])
        NormalModeController.shared.enter()
        let pane = try focusedPane()
        defer { pane.removeFromSuperview() }

        XCTAssertTrue(runner.handleKeyDown(try keyDown("g", keyCode: 5), in: window), "the first chord arms")
        XCTAssertTrue(NormalModeController.shared.isArmed)
        XCTAssertTrue(runner.handleKeyDown(try escapeKey(), in: window))

        XCTAssertFalse(NormalModeController.shared.isArmed, "esc drops the half-typed sequence")
        XCTAssertTrue(NormalModeController.shared.isActive, "abandoning a leader is not leaving the mode")
        XCTAssertTrue(escapeTargets.isEmpty, "no keystroke may leak into the pane while the mode is still on")
    }

    /// With focus on the window rather than a pane there is nothing to hand the Escape to, so Esc is the plain
    /// exit it always was.
    func testEscapeWithNoFocusedPaneJustLeavesTheMode() throws {
        XCTAssertTrue(runner.handleKeyDown(try escapeKey(), in: window))

        XCTAssertFalse(NormalModeController.shared.isActive)
        XCTAssertTrue(escapeTargets.isEmpty)
    }

    /// Holding a bare key is the mode's headline move — `k` held down walks back through sessions — so the
    /// repeat guard the custom-command path keeps must not sit in front of the mode.
    func testAHeldBoundKeyRepeatsItsAction() throws {
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
    /// otherwise eat every key before the overlay's pty saw one. The mode YIELDS instead of exiting, so the
    /// editor a bind opened hands the user back to the mode on quit.
    func testAProgramOverlayYieldsTheModeAndReleasesItsKeysWithoutEndingIt() throws {
        let (store, session) = try selectedSession()
        // the mode yields only to an overlay that APPEARED on the target the previous key saw, so this
        // session has to be that target first. `q` binds to nothing: swallowed, consumed, fires nothing.
        XCTAssertTrue(runner.handleKeyDown(try keyDown("q", keyCode: 12), in: window))
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))

        XCTAssertFalse(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                       "the overlay's program must receive the key")
        XCTAssertTrue(fired.isEmpty, "the bind must not fire behind the overlay")
        XCTAssertTrue(NormalModeController.shared.isActive, "yielding is not exiting")

        store.closeOverlay(session.id)
        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "the very next key after the overlay closes is the mode's again")
        XCTAssertEqual(fired, [.toggleSplit])
    }

    /// A HUD is a passive message panel that takes no keystrokes, so it must leave the mode driving — the
    /// yield asks `programOverlayOwnsKeyboard`, never the raw slot.
    func testAHudDoesNotYieldTheMode() throws {
        let (store, session) = try selectedSession()
        // the HUD has to be an APPEARANCE on the remembered target, or the key would read as an arrival and
        // this would pass however `programOverlayOwnsKeyboard` answers.
        XCTAssertTrue(runner.handleKeyDown(try keyDown("q", keyCode: 12), in: window))
        XCTAssertTrue(store.openHud(session.id, command: "true", spec: HudSpec(message: "working"),
                                    file: (NSTemporaryDirectory() as NSString).appendingPathComponent("hud-body"),
                                    size: HudPanelSize(widthPercent: 40, heightPercent: 20)))

        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "a HUD covers nothing, so the mode still owns the key")
        XCTAssertEqual(fired, [.toggleSplit])
        XCTAssertTrue(NormalModeController.shared.isActive)
    }

    /// The yield drops the MODE's half-typed sequence like every other way out of the terminal does: the
    /// chord that would have completed it went to the overlay, so re-arming from the first chord is the only
    /// honest state to come back to. The GLOBAL matcher's own prefix survives instead — see
    /// `testAGlobalLeaderSequenceStillCompletesWhileYielded`.
    func testAnOverlayAbandonsAHalfTypedLeader() throws {
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

    /// ⚠️ An overlay already running when she arrives keeps the keys, or `j`/`k` would trap her under it.
    func testWalkingOntoASessionWhoseOverlayIsAlreadyOpenKeepsTheKeyboard() throws {
        let (store, _) = try selectedSession()
        XCTAssertTrue(runner.handleKeyDown(try keyDown("q", keyCode: 12), in: window), "remembers the target")
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let second = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        XCTAssertTrue(store.openOverlay(second.id, command: "vifm"))
        store.selectSession(second.id)

        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "the overlay was there before she arrived, so the key is still the mode's")
        XCTAssertEqual(fired, [.toggleSplit])
        XCTAssertTrue(NormalModeController.shared.isActive)
    }

    /// Entry forgets the remembered target, so the first key after it is the mode's even over a live overlay.
    func testEnteringOverALiveOverlayTakesTheKeyboard() throws {
        let (store, session) = try selectedSession()
        XCTAssertTrue(runner.handleKeyDown(try keyDown("q", keyCode: 12), in: window))
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))
        XCTAssertFalse(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window), "the overlay appeared")
        XCTAssertTrue(fired.isEmpty)

        NormalModeController.shared.exit()
        NormalModeController.shared.enter()

        XCTAssertTrue(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "re-entering over the same overlay owns the keyboard again")
        XCTAssertEqual(fired, [.toggleSplit])
    }

    /// A yielded key falls through to the global matcher, so the enter chord takes the keyboard back.
    func testTheEnterChordWhileYieldedReachesTheGlobalMatcherAndTakesTheKeyboardBack() throws {
        let seeded = try seededRunner(keymap: "map ctrl+space normal_mode\nnmap s toggle_split\n")
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()
        let (store, session) = try selectedSession()
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("q", keyCode: 12), in: window))
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))
        XCTAssertFalse(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window), "the overlay appeared")

        XCTAssertTrue(seeded.handleKeyDown(try keyDown(" ", keyCode: 49, flags: .control), in: window),
                      "the enter chord reaches the global matcher and is consumed there")
        XCTAssertEqual(fired, [.normalMode])

        XCTAssertTrue(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window))
        XCTAssertEqual(fired, [.normalMode, .toggleSplit], "the key after the chord is the mode's again")
    }

    /// ⚠️ `toggle_fullscreen` has no menu item, so a yielded ⌘⌃F reaches the matcher or reaches nothing.
    func testTheFullScreenChordStillTogglesWhileYielded() throws {
        let recording = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        recording.isReleasedWhenClosed = false
        let recordingID = UUID()
        WindowRegistry.shared.register(recordingID, window: recording)
        defer {
            WindowRegistry.shared.unregister(recordingID)
            recording.orderOut(nil)
        }
        let (store, session) = try selectedSession()
        XCTAssertTrue(runner.handleKeyDown(try keyDown("q", keyCode: 12), in: recording))
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))
        // ⌘⌃F toggles from the non-yielded path too, so the yield has to be established in this same test or
        // the case cannot tell the two dispatches apart.
        XCTAssertFalse(runner.handleKeyDown(try keyDown("s", keyCode: 1), in: recording),
                       "the overlay appeared under her, so the bare key went to the program")
        XCTAssertTrue(fired.isEmpty)

        XCTAssertTrue(runner.handleKeyDown(try keyDown("f", keyCode: 3, flags: [.control, .command]),
                                           in: recording))

        XCTAssertEqual(recording.toggleCount, 1, "⌘⌃F must survive the yield")
        XCTAssertTrue(NormalModeController.shared.isActive, "full screen is not a way out of the mode")
    }

    /// ⚠️ Yielded means what the mode being OFF means, so a global leader sequence must survive the yield.
    func testAGlobalLeaderSequenceStillCompletesWhileYielded() throws {
        let seeded = try seededRunner(keymap: "map ctrl+a>s toggle_split\n")
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()
        let (store, session) = try selectedSession()
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("q", keyCode: 12), in: window))
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))

        XCTAssertTrue(seeded.handleKeyDown(try keyDown("a", keyCode: 0, flags: .control), in: window),
                      "the first chord reaches the global matcher and arms it")
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "the second chord completes the sequence instead of being dropped")

        XCTAssertEqual(fired, [.toggleSplit])
        XCTAssertTrue(NormalModeController.shared.isActive)
    }

    /// ⚠️ A key the MODE takes must drop a global leader a yielded key armed, or nothing can time it out.
    func testAKeyTheModeTakesDropsAGlobalLeaderArmedWhileYielded() throws {
        let seeded = try seededRunner(keymap: "map ctrl+a>s toggle_split\nnmap z next_session\n")
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()
        let (store, session) = try selectedSession()
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("q", keyCode: 12), in: window), "remembers the target")
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("a", keyCode: 0, flags: .control), in: window),
                      "the yielded chord reaches the global matcher and arms it")

        store.closeOverlay(session.id)
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("z", keyCode: 6), in: window),
                      "the keyboard is the mode's again, so the mode takes this key")
        XCTAssertEqual(fired, [.nextSession])

        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))
        XCTAssertFalse(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                       "with the stale prefix gone this key is the overlay program's")
        XCTAssertEqual(fired, [.nextSession], "no half-typed `map ctrl+a>s` may complete behind it")
    }

    /// ⚠️ Losing key ends the mode and has to drop the global leader with it, or that prefix outlives it.
    func testTheKeyWindowResigningKeyDropsAStrandedGlobalLeader() throws {
        let seeded = try seededRunner(keymap: "map ctrl+a>s toggle_split\n")
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()
        let (store, session) = try selectedSession()
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("q", keyCode: 12), in: window), "remembers the target")
        XCTAssertTrue(store.openOverlay(session.id, command: "vifm"))
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("a", keyCode: 0, flags: .control), in: window),
                      "the yielded chord reaches the global matcher and arms it")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(NormalModeController.shared.isActive, "losing key ends the mode")

        store.closeOverlay(session.id)
        XCTAssertFalse(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                       "with the mode gone this key is the terminal's")
        XCTAssertTrue(fired.isEmpty, "no half-typed `map ctrl+a>s` may complete behind the mode's exit")
    }

    /// ⚠️ A Command chord that only STARTS a sequence is handed back, not eaten: its tail is bare, so the
    /// mode swallows it and the sequence can never complete.
    func testACommandLeaderThatCanNeverCompleteIsNotEatenWhileTheModeOwnsTheKeys() throws {
        let seeded = try seededRunner(keymap: "map cmd+r>t new_session\nnmap s toggle_split\n")
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()

        XCTAssertFalse(seeded.handleKeyDown(try keyDown("r", keyCode: 15, flags: .command), in: window),
                       "a sequence the mode would break must not consume its first chord")
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("t", keyCode: 17), in: window),
                      "the bare tail is the mode's, like every other bare key")
        XCTAssertTrue(fired.isEmpty, "the sequence must not fire from behind the mode")
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window))
        XCTAssertEqual(fired, [.toggleSplit], "the mode's own binds are untouched")

        // positive control: the same two keys fire with the mode off, so the assertions above are the mode
        // holding the tail rather than a keymap that never parsed.
        NormalModeController.shared.exit()
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("r", keyCode: 15, flags: .command), in: window))
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("t", keyCode: 17), in: window))
        XCTAssertEqual(fired, [.toggleSplit, .newSession])
    }

    /// ⚠️ A custom command bound to a Command chord has no menu item either, so it too rides the matcher.
    func testACommandChordBoundToACustomCommandStillFiresWhileTheModeOwnsTheKeys() throws {
        let marker = stateDir.appendingPathComponent("fired.txt")
        let seeded = try seededRunner(keymap: """
        command "Marker" cmd+ctrl+m echo x >> "\(marker.path)"
        nmap s toggle_split
        """)
        seeded.start()
        defer { seeded.stop() }
        NormalModeController.shared.enter()

        XCTAssertTrue(seeded.handleKeyDown(try keyDown("m", keyCode: 46, flags: [.command, .control]),
                                           in: window),
                      "the matcher owns the chord, so it consumes it rather than passing it to the menu bar")
        XCTAssertTrue(waitForMarkerLines(marker, count: 1), "the bound command must actually run")
        XCTAssertTrue(NormalModeController.shared.isActive, "firing it is not a way out of the mode")
        XCTAssertTrue(seeded.handleKeyDown(try keyDown("s", keyCode: 1), in: window),
                      "the bare keys are still the mode's")
        XCTAssertEqual(fired, [.toggleSplit])
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
                                   performBuiltin: { [weak self] in self?.record($0) },
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
