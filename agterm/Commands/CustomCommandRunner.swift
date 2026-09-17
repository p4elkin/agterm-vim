import agtermCore
import AppKit
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "CustomCommandRunner")

/// How the runner shows a failed command: posts the panel, answering false when the slot holds a running
/// program, which is never evicted for a message. Taking it down again is the panel's own auto-hide.
struct FailureHud {
    let open: (_ sessionID: String, _ message: String, _ detail: String?) -> Bool
}

/// A command's stderr, captured to a temp file so a failure can say what it printed.
///
/// A FILE rather than a pipe: a pipe's read end lives only as long as agterm, so a background process a
/// chord started would take SIGPIPE on its next write once the app quit, where inheriting `/dev/null` let it
/// run on. A file also needs no reader, so nothing can block on a full buffer and nothing of ours outlives
/// the command.
private struct StderrFile: @unchecked Sendable {
    let url: URL
    let handle: FileHandle

    /// Nil when the file cannot be created; the caller then sends stderr to `/dev/null` as before.
    init?() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-command-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    /// The last `CommandFailure.tailLimit` bytes the command wrote, after which the file is removed. The cap
    /// is on the READ: the file itself holds everything written to it, and a background descendant that
    /// inherited it keeps growing the unlinked inode, whose space returns only when that process exits.
    func consume() -> [UInt8] {
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        guard let reader = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? reader.close() }
        let size = (try? reader.seekToEnd()) ?? 0
        // read the sampled interval, not to the end: a descendant appending between the two would otherwise
        // hand back everything it wrote as well.
        let wanted = min(size, UInt64(CommandFailure.tailLimit))
        try? reader.seek(toOffset: size - wanted)
        return [UInt8]((try? reader.read(upToCount: Int(wanted))) ?? Data())
    }
}

/// Drives user-defined custom commands: an app-wide `NSEvent` local key monitor turns key presses into
/// chords, a `CustomCommandEngine` resolves them (simple chords and leader sequences like `ctrl+a > g`), and
/// a fired command runs detached as `/bin/sh -c` with the session's context in `{AGT_X}` tokens and `$AGT_X`
/// environment. The same matcher also carries the built-in binds an `NSMenuItem` key equivalent cannot hold —
/// a `map` line's alternatives beyond its first single chord — dispatched through `AppActions.perform(_:in:)`.
///
/// Constructed once as `@State` in `agtermApp`. `start()`/`stop()` install/remove the monitor; `start()` is
/// idempotent because the scene `.task` fires once per window, and the matcher rebuilds there and on
/// `.agtermKeymapChanged`. Pure parsing/matching/expansion lives in agtermCore; this maps `NSEvent` → core
/// types, owns the leader timer, resolves the surface's session via the host-free `WindowLibrary`, and spawns.
@MainActor
final class CustomCommandRunner {
    private let library: WindowLibrary
    private let settings: SettingsModel
    private let actions: AppActions
    private let socketProvider: () -> String
    /// Posts the failure panel over the session a command fired in; the panel's own auto-hide takes it down.
    /// Injected rather than reached for: the control server owns the HUD path, and a test supplies a recorder.
    private let failureHud: FailureHud?

    private var commandEngine = CustomCommandEngine(commands: [])

    private var keyMonitor: Any?
    private var leaderTimer: Timer?
    private var keymapObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?

    private let normalMode = NormalModeController.shared

    /// How long a half-typed leader sequence waits for its next chord before abandoning (kitty-style).
    private static let leaderTimeout: TimeInterval = 1.5

    /// How long a failure panel stays up: long enough to read a line, short enough that a message about a
    /// command that has already finished is not still sitting over the session minutes later.
    static let failureHudSeconds: TimeInterval = 10

    /// Run counts behind the title-bar popover's most-used section; every spawn path records into it.
    let usage: CustomCommandUsageStore

    init(library: WindowLibrary, settings: SettingsModel, actions: AppActions, usage: CustomCommandUsageStore,
         socketProvider: @escaping () -> String, failureHud: FailureHud? = nil) {
        self.library = library
        self.settings = settings
        self.actions = actions
        self.usage = usage
        self.socketProvider = socketProvider
        self.failureHud = failureHud
    }

    /// Install the local `.keyDown` monitor (idempotent), build the keybind map, observe `.agtermKeymapChanged`.
    func start() {
        guard keyMonitor == nil else { return }
        rebuild()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // returning nil consumes the event (it never reaches the terminal); event passes it through.
            return self.handleKeyDown(event) ? nil : event
        }
        keymapObserver = NotificationCenter.default.addObserver(
            forName: .agtermKeymapChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        // normal mode swallows keys and shows only in the key window's titlebar, so it must not survive that
        // window losing key — armed and invisible in the background is exactly how a user gets stuck.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.normalMode.isActive else { return }
                // both matchers, not just the timer: a yielded key arms the GLOBAL one while the mode is on,
                // and cancelling the timer alone would leave that prefix armed with nothing to time it out.
                self.abandonLeader()
                self.normalMode.exit()
            }
        }
    }

    /// Remove the monitor, both observers, and any pending leader timer.
    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let keymapObserver { NotificationCenter.default.removeObserver(keymapObserver) }
        keymapObserver = nil
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        cancelLeaderTimer()
    }

    /// Rebuild the matcher from the current keymap — custom commands plus the built-in monitor binds — skipping
    /// empty shortcuts (palette-only commands have none). `parseKeymap`'s cross-section validation already
    /// empties the shortcut of a command colliding with a built-in or another custom one, so it drops out of
    /// the matcher.
    private func rebuild() {
        let keymap = settings.keymap
        var sequences = keymap.builtinSequences
        // `normal_mode` owns no menu item, so a single-chord `map ctrl+space normal_mode` lands in
        // `builtinOverrides` with nothing to dispatch it. Hand that chord to the monitor too, ahead of the
        // alternatives the same line left, which the parser already checked it cannot collide with.
        if let chord = keymap.equivalent(for: .normalMode) {
            sequences[.normalMode, default: []].insert([chord], at: 0)
        }
        // same reasoning for `overlay_redirect_toggle` (fork only): keyless, and no menu item to carry it.
        if let chord = keymap.equivalent(for: .overlayRedirectToggle) {
            sequences[.overlayRedirectToggle, default: []].insert([chord], at: 0)
        }
        // and for `new_session_in_workspace` (fork only): the three palette launchers escape this block only
        // because Navigate carries their chords; this one has no menu item.
        if let chord = keymap.equivalent(for: .newSessionInWorkspace) {
            sequences[.newSessionInWorkspace, default: []].insert([chord], at: 0)
        }
        commandEngine = CustomCommandEngine(commands: keymap.commands, builtinSequences: sequences)
        normalMode.rebuild(binds: keymap.normalModeBinds)
        cancelLeaderTimer()
    }

    /// The Esc virtual keycode the matcher treats specially (the leader abort); Return is bindable and goes
    /// through `namedKey(forKeyCode:)`.
    private static let escapeKeyCode = InterruptKeystroke.escapeKeyCode

    /// Hands normal mode's Esc down to the pane as a real Escape keypress. A stored closure for the same
    /// reason as `AppActions.keyWindowProvider`: a hosted test's pane has no libghostty surface, so the send
    /// itself leaves no trace to assert on.
    var escapeSender: @MainActor (GhosttySurfaceView) -> Void = { $0.sendEscapeKey() }

    /// Test seam beside `escapeSender`: performing a built-in needs the windows, sessions and palette state a
    /// hosted test cannot build, so those record the action instead. Nil dispatches through the real hub.
    var builtinPerformer: (@MainActor (BuiltinAction, NSWindow) -> Void)?

    /// Feed one key event to the matcher; returns whether it was consumed (so the caller drops it). Normal
    /// mode takes the key first and consumes all but the chords it declines. Otherwise Esc while armed
    /// resets, `.fired` runs a command, `.firedBuiltin` runs a built-in action, `.armed` arms the leader
    /// timer unless normal mode still owns the bare keys, and `toggle_fullscreen`'s chord toggles full
    /// screen without reaching the matcher at all — all consumed but that un-armed case; `.unmatched`
    /// passes through.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        return handleKeyDown(event, in: keyWindow)
    }

    /// The decision half, taking the key window instead of reading `NSApp.keyWindow`, so hosted tests can
    /// drive it against a window they own: a hosted test's own window never becomes `NSApp.keyWindow` (the
    /// app is not active), so `handleKeyDown(_:)` returns at that guard and none of this runs. Internal for
    /// that reason alone, like `ControlServer.collectKeyEquivalents`.
    ///
    /// Acts when the key window's first responder is a terminal surface (context from that surface), or when
    /// the key window is an agterm terminal window whose focus is NOT on a text field — including one emptied
    /// to zero sessions. Passes through for a focused text field (Settings editor, inline rename, palette
    /// search) so a bound chord never eats those keystrokes, and for an auxiliary window focused off a text
    /// field.
    func handleKeyDown(_ event: NSEvent, in keyWindow: NSWindow) -> Bool {
        let responder = keyWindow.firstResponder
        // a focused text field is the window's NSText field editor and must keep its keystrokes: drop the
        // half-typed leader, LEAVE normal mode, pass through. the mode binds bare keys, so one left on over a
        // field would eat the typing — and a field is focused only because the user asked to type into it,
        // including through a mode bind that opened a palette.
        if responder is NSText {
            abandonLeader()
            if normalMode.isActive { normalMode.exit() }
            return false
        }
        let focusedSurface = responder as? GhosttySurfaceView
        // with no focused surface, fire ONLY from an agterm terminal window (empty qualifies), never Settings.
        guard focusedSurface != nil || WindowRegistry.shared.contains(keyWindow) else {
            abandonLeader()
            return false
        }
        // normal mode takes the key ahead of the global matcher: its binds are bare keys that would otherwise
        // fall through to whatever the global map holds. The flag carries the one key that reaches the
        // matcher below with the mode still holding every bare key — the `.armed` case is what that costs.
        var modeOwnsBareKeys = false
        if normalMode.isActive {
            // terminal zoom, the dashboard grid or a pending picker owns the keyboard for the same reason a
            // focused text field does, and needs the arrows and Return the mode would swallow. Entry is
            // gated on this predicate already; this is the re-check for a modal opened WHILE the mode was
            // on — an `nmap dashboard` bind, or a control command.
            guard AppActions.uiActionsEnabled(for: library.activeWindowID) else {
                abandonLeader()
                normalMode.exit()
                return false
            }
            // a caller's program in an overlay owns the keyboard until it exits, and the mode yields to it
            // for as long as it does — an event rather than a state, and not an exit either.
            // `NormalModeOverlayHandover` owns that rule; [[keymap]] says where this call has to sit.
            let active = library.activeStore?.activeSession
            let yielded = normalMode.stepOverlayHandover(session: active?.id,
                                                         pane: active?.focusedPane ?? .left,
                                                         ownsKeyboard: active?.programOverlayOwnsKeyboard == true)
            if yielded, normalMode.isArmed {
                // the MODE's half-typed leader only, never `abandonLeader()`: the chord that would have
                // completed it went to the program, while the GLOBAL prefix is armed BY yielded keys and has
                // to survive. Cancelling the shared timer is safe because arming the mode's leader resets
                // the global matcher, so only one of the two is ever armed.
                normalMode.reset()
                cancelLeaderTimer()
            }
            // two kinds of key are not the mode's and fall through to the global matcher below: a YIELDED
            // one, because yielded means what the mode being OFF means, and a COMMAND chord with no mode
            // leader armed, because the built-ins and custom commands bound to one have no menu item behind
            // the monitor and would otherwise reach nothing at all. See [[keymap]].
            let fallsThroughToMatcher = yielded
                || (event.modifierFlags.contains(.command) && !normalMode.isArmed)
            guard fallsThroughToMatcher else {
                return handleNormalModeKey(event, in: keyWindow, focusedSurface: focusedSurface)
            }
            modeOwnsBareKeys = !yielded
        }
        // a key repeat drives neither a custom command nor a global leader, so a held-down shortcut spawns
        // one process rather than one per OS repeat. Normal mode above deliberately TAKES repeats: holding
        // `k` to skim back through sessions is what a bare-key bind is for.
        guard !event.isARepeat else { return false }
        // esc abandons a half-typed leader (the call the timeout makes) and is not bindable, so it comes
        // before the chord.
        if event.keyCode == Self.escapeKeyCode {
            guard commandEngine.isArmed else { return false }
            commandEngine.reset()
            cancelLeaderTimer()
            return true
        }
        guard let chord = chord(from: event) else {
            // a key with no usable base (e.g. a bare modifier) can't advance; while armed, keep waiting.
            return false
        }
        // `toggle_fullscreen` is the one built-in with no menu item to carry its equivalent: AppKit appends
        // the only full screen item there is, at menu-display time, and an item of agterm's own beside it is
        // the duplicate this avoids. So the rebindable chord is matched here instead. A half-typed leader
        // sequence still wins, exactly as it does over a custom command sharing its first chord.
        // Its MENU chord alone comes through here, ungated; an alternative of the same `map` line goes the
        // ordinary `.firedBuiltin` route and so takes that route's modal rule.
        if !commandEngine.isArmed, chord == settings.keymap.equivalent(for: .toggleFullscreen) {
            keyWindow.toggleFullScreen(nil)
            return true
        }
        switch commandEngine.advance(chord) {
        case .fired(let command):
            cancelLeaderTimer()
            if let focusedSurface {
                // context from the surface that had focus at key-down, not the frontmost active session.
                runFromKeybind(command, focusedSurface: focusedSurface)
            } else {
                // no fired-from surface: the active session if one exists, else the launcher path.
                runNoSurface(command)
            }
            return true
        case .firedBuiltin(let action):
            cancelLeaderTimer()
            // no focusedSurface/runNoSurface split: a built-in acts on the active session and key window,
            // like the palette row behind it. Consumed even when `perform` finds the action gated out: the
            // gate lives inside each action, so this cannot see the outcome, and passing a leader's LAST chord
            // through after swallowing its prefix would type a stray character into the terminal.
            performBuiltin(action, in: keyWindow)
            return true
        case .armed:
            // only a Command chord reaches here with the mode still owning the bare keys, and the sequence
            // it would start can never finish: the next chord is bare and the mode swallows it. So hand the
            // chord back like an unmatched one rather than eat it for a sequence that cannot fire.
            guard !modeOwnsBareKeys else {
                dropGlobalLeader()
                return false
            }
            startLeaderTimer()
            return true
        case .unmatched:
            cancelLeaderTimer()
            return false
        }
    }

    /// Feed one key event to normal mode and report whether the monitor consumed it. This monitor is the only
    /// thing between the mode and the terminal — nothing holds first responder for it — so every outcome but
    /// `.inactive` is CONSUMED, an unmatched key included.
    ///
    /// Two exceptions are handed straight back. A Command chord, which reaches here only with a normal-mode
    /// leader armed (the caller routes every other one to the global matcher): the monitor runs ahead of
    /// `performKeyEquivalent`, so consuming one would swallow ⌘Q and leave no way out of the mode. And a
    /// reserved monitor chord (`isReservedMonitorChord` — ctrl+tab, ctrl+1/2): those live in the switcher
    /// and pane-shortcut monitors, which run whatever the mode is, and nothing orders the four `.keyDown`
    /// monitors, so consuming one here would let registration order decide whether ⌃Tab works. Both are
    /// therefore unreachable as `nmap` binds, which is why the parser rejects them.
    private func handleNormalModeKey(_ event: NSEvent, in keyWindow: NSWindow,
                                     focusedSurface: GhosttySurfaceView?) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
        let outcome: NormalModeState.Outcome
        if event.keyCode == Self.escapeKeyCode {
            // esc has no `Chord` spelling, so it arrives through its own entry point.
            outcome = normalMode.escape()
            // ⚠️ Esc LEAVING the mode carries down into the pane, so vim, shell vi-mode and Claude Code's vim
            // mode land in normal mode too — `i` means insert at both layers, Esc means normal at both. Only
            // on `.exited`: Esc that merely abandons a half-typed leader stays in the mode, and an Escape
            // delivered there would reach the shell from behind a mode that is still swallowing keys.
            // `advance`'s `.exited` (the `i` exit key) sends nothing, which is why this reads escape()'s own
            // result instead of the switch below.
            if outcome == .exited, let focusedSurface { escapeSender(focusedSurface) }
        } else if let chord = chord(from: event) {
            guard !isReservedMonitorChord(chord) else { return false }
            outcome = normalMode.advance(chord)
        } else {
            // a bare modifier can't advance anything; while armed, keep waiting.
            return false
        }
        switch outcome {
        case .fired(let action):
            dropGlobalLeader()
            // the same seam a `.firedBuiltin` chord takes, so an `nmap` bind does exactly what the palette row
            // behind its action does, gate included.
            performBuiltin(action, in: keyWindow)
            return true
        case .armed:
            commandEngine.reset()
            startLeaderTimer()
            return true
        case .firedCommand(let id):
            dropGlobalLeader()
            // the mode honors OS key repeats so a held bare key can skim sessions; a command target must NOT
            // inherit that, or holding the key spawns one process per repeat. The key stays consumed either way.
            guard !event.isARepeat else { return true }
            guard let command = settings.keymap.commands.first(where: { $0.id == id }) else { return true }
            if let focusedSurface {
                runFromKeybind(command, focusedSurface: focusedSurface)
            } else {
                runNoSurface(command)
            }
            return true
        case .exited, .swallowed:
            dropGlobalLeader()
            return true
        case .inactive:
            return false
        }
    }

    /// End any half-typed GLOBAL leader. Both matchers CAN be armed at once — a yielded key arms the global
    /// one while the mode is on — and cancelling the shared timer without resetting it strands that prefix
    /// with no timeout, in front of the `isArmed`-guarded `toggle_fullscreen` dispatch above.
    private func dropGlobalLeader() {
        commandEngine.reset()
        cancelLeaderTimer()
    }

    /// The one path a monitor-dispatched built-in takes, so a `.firedBuiltin` chord and an `nmap` bind cannot
    /// drift apart.
    private func performBuiltin(_ action: BuiltinAction, in window: NSWindow) {
        if let builtinPerformer { builtinPerformer(action, window) } else { actions.perform(action, in: window) }
    }

    /// Map an `NSEvent` key-down to an agtermCore `Chord`, or nil when it carries no usable base key. The base
    /// key is the named special key, else what `chordKey` resolves — the unmodified character on a layout that
    /// can type ASCII, the physical position on one that cannot.
    private func chord(from event: NSEvent) -> Chord? {
        var mods: Modifier = []
        let flags = event.modifierFlags
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }

        if let named = namedKey(forKeyCode: event.keyCode) {
            return Chord(mods: mods, key: named)
        }
        // `characters(byApplyingModifiers: [])` gives the UNSHIFTED base key (shift+/ → "/"), matching how
        // the keymap spells `shift+<base>`. `charactersIgnoringModifiers` instead KEEPS shift (shift+/ → "?")
        // and `.lowercased()` undoes that only for letters, so punctuation would land on the shifted glyph
        // and never match a `shift+/` binding. `chordKey` then applies the layout rule, so `cmd+o` still
        // fires on a Cyrillic layout (the key types `щ`).
        let produced = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        guard let key = chordKey(forKeyCode: event.keyCode, produced: produced,
                                 layoutIsASCIICapable: KeyboardLayout.isASCIICapable) else { return nil }
        return Chord(mods: mods, key: key)
    }

    private func startLeaderTimer() {
        cancelLeaderTimer()
        leaderTimer = Timer.scheduledTimer(withTimeInterval: Self.leaderTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // one timer for both armed leaders — only one can be armed, and resetting the other is a no-op.
                self.commandEngine.reset()
                self.normalMode.reset()
                self.leaderTimer = nil
            }
        }
    }

    private func cancelLeaderTimer() {
        leaderTimer?.invalidate()
        leaderTimer = nil
    }

    /// Drop both matchers and the shared timer. Every caller that also leaves normal mode calls this FIRST:
    /// the guard reads the mode's leader, which `normalMode.exit()` has already cleared.
    private func abandonLeader() {
        guard commandEngine.isArmed || normalMode.isArmed else { return }
        commandEngine.reset()
        normalMode.reset()
        cancelLeaderTimer()
    }

    /// Run a command fired from the PALETTE: context from the active session (the palette has no first
    /// responder to key off). No-op with no window/session — a session-scoped command with silently-empty
    /// tokens is unsafe (an empty `{AGT_SESSION_PWD}` turns `rm -rf …/*` into a root glob), so only the
    /// deliberate empty-window KEYBIND path fires a session-free launcher.
    func run(_ command: CustomCommand) {
        guard let store = library.activeStore, let session = store.activeSession else {
            logger.notice("custom command \"\(command.name, privacy: .public)\" fired with no active session; ignored")
            return
        }
        // selection + pane come from the active session's focused pane; with no fired-from surface the focus
        // flag is the source, gated on the split surface EXISTING. right after `session split on`,
        // `splitFocused` is already true while `splitSurface` is still nil, so a bare flag would report
        // `.right` off a nil surface while `session.type --pane right` still errors "no split pane". a
        // promoted survivor sits in the `surface` slot with both nil/false, so `.left`.
        let onSplit = session.splitFocused && session.splitSurface != nil
        let selectionSurface = (onSplit ? session.splitSurface : session.surface) as? GhosttySurfaceView
        spawn(command, for: session, in: store, selectionSurface: selectionSurface, pane: onSplit ? .right : .left)
    }

    /// Run a command fired by KEYBIND: context from the surface that had focus at key-down, so a chord from a
    /// split/scratch (or during a window-switch race) runs against THAT surface's session/cwd/window and reads
    /// its selection. A sessionless focused surface routes through `runFromSessionlessSurface`.
    func runFromKeybind(_ command: CustomCommand, focusedSurface: GhosttySurfaceView) {
        guard let session = focusedSurface.session, let store = store(owning: session) else {
            runFromSessionlessSurface(command, focusedSurface: focusedSurface)
            return
        }
        // the pane is the surface's identity, not the focus flag, so a chord reports the pane it was typed in
        // even before the flag catches up.
        let pane: CommandContext.Pane = (session.splitSurface as? GhosttySurfaceView) === focusedSurface ? .right : .left
        spawn(command, for: session, in: store, selectionSurface: focusedSurface, pane: pane)
    }

    /// The open store holding `session` itself. Matched by object identity rather than through
    /// `store(forSession:)`, which answers with the first window carrying that id and a snapshot written by
    /// an older build can put one id in two windows.
    private func store(owning session: Session) -> AppStore? {
        for windowID in library.openIDs() {
            guard let store = library.store(for: windowID) else { continue }
            if store.workspaces.contains(where: { $0.sessions.contains { $0 === session } }) { return store }
        }
        return nil
    }

    /// Resolve the surface and its owning store together, since a session id can repeat across windows.
    /// The quick terminal has no session owner and keeps the active-session fallback.
    private func runFromSessionlessSurface(_ command: CustomCommand, focusedSurface: GhosttySurfaceView) {
        for windowID in library.openIDs() {
            guard let store = library.store(for: windowID) else { continue }
            for session in store.workspaces.flatMap(\.sessions) {
                guard let pane = sessionlessPane(of: focusedSurface, in: session) else { continue }
                spawn(command, for: session, in: store, selectionSurface: focusedSurface, pane: pane)
                return
            }
        }
        runNoSurface(command)
    }

    /// Which pane `session`'s sessionless surface reports as `$AGT_PANE`, nil when the surface is not one of
    /// them (the quick terminal). The scratch names itself; an overlay names the surface UNDERNEATH it, so a
    /// note taken in it still pastes back through `session type --pane` — the overlay's own buffer is
    /// `session overlay copy`/`text`, which `CommandContext.Pane` deliberately cannot spell.
    private func sessionlessPane(of surface: GhosttySurfaceView, in session: Session) -> CommandContext.Pane? {
        if (session.scratchSurface as? GhosttySurfaceView) === surface { return .scratch }
        let overlayPane = session.paneOverlayRole(of: surface)
        guard overlayPane != nil || (session.overlaySurface as? GhosttySurfaceView) === surface else {
            return nil
        }
        // what is underneath is what `topmostSurface` resolves once this overlay closes, and that is the
        // SCRATCH whenever one is up: a session-wide overlay sits above it, and it in turn covers a pane
        // overlay. Naming a pane there routes the reply into a surface the user cannot see.
        if session.scratchActive { return .scratch }
        guard let overlayPane else { return session.focusedPane == .right ? .right : .left }
        return overlayPane == .right ? .right : .left
    }

    /// Keybind fire with NO usable fired-from session — an emptied window, or focus off any surface. Uses the
    /// active session's context when one exists, like the palette, else `spawnSessionless`.
    private func runNoSurface(_ command: CustomCommand) {
        if library.activeStore?.activeSession != nil {
            run(command)
        } else {
            spawnSessionless(command)
        }
    }

    /// Fire `command` with a session-free context (the empty-window launcher path) — UNLESS its body names
    /// session-scoped tokens, which expand dangerously empty (an empty `{AGT_SESSION_PWD}` makes `rm -rf …/*`
    /// a root glob, defeating even the quoted `$AGT_X` form); that NO-OPS with a notice. A launcher naming
    /// only `AGT_SOCKET`/`AGT_WINDOW`/`AGT_PANE` still fires.
    private func spawnSessionless(_ command: CustomCommand) {
        guard !CommandContext.referencesSessionScopedContext(command.command) else {
            logger.notice("custom command \"\(command.name, privacy: .public)\" references session context but no session is active; ignored")
            return
        }
        spawn(command, context: sessionlessContext(), cwd: nil)
    }

    /// Spawn for a session pane: the context carries the pane's reported cwd raw, while the process starts
    /// where `Session.localWorkingDirectory` says, widened here to ANY row whose reported path is not a local
    /// directory, not just a remote one. `Process.run()` validates `currentDirectoryURL` inside the spawn and
    /// throws before `/bin/sh` is exec'd, so a local row whose directory was deleted or replaced by a file
    /// loses the command exactly as a remote row did (measured 2026-09-09).
    private func spawn(_ command: CustomCommand, for session: Session, in store: AppStore,
                       selectionSurface: GhosttySurfaceView?, pane: CommandContext.Pane) {
        let context = self.context(for: session, in: store, selectionSurface: selectionSurface, pane: pane)
        let home = NSHomeDirectory()
        var cwd = session.localWorkingDirectory(reported: context.sessionPWD, homeDirectory: home)
        var isDirectory: ObjCBool = false
        let resolves = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
        if !cwd.isEmpty, !resolves {
            logger.notice("""
                custom command "\(command.name, privacy: .public)" runs from home: \
                \(cwd, privacy: .public) is not a local directory
                """)
            cwd = home
        }
        spawn(command, context: context, cwd: cwd)
    }

    /// Resolve every `{AGT_X}` token for the given session: ids + cwd + remote host from the model, names
    /// from the owning workspace/window, the selection from `selectionSurface`, the fired-from pane from the
    /// caller (`left`|`right`|`scratch`) with the token of the surface in that slot, the socket from the
    /// control server. The token is read from the slot, not from `selectionSurface`: for an overlay chord
    /// that view is the overlay itself, which has no token, while `pane` names the terminal underneath.
    private func context(for session: Session, in store: AppStore, selectionSurface: GhosttySurfaceView?,
                         pane: CommandContext.Pane) -> CommandContext {
        let workspace = store.workspace(forSession: session.id)
        let windowID = library.windowID(for: store)
        let windowName = library.windowName(for: windowID)
        return CommandContext(
            sessionID: session.id.uuidString,
            sessionName: session.displayName,
            sessionPWD: session.cwd(for: pane),
            sessionHost: TerminalText.sanitized(session.remoteHost ?? ""),
            workspaceID: workspace?.id.uuidString ?? "",
            workspaceName: workspace?.name ?? "",
            windowID: windowID?.uuidString ?? "",
            windowName: windowName,
            pane: pane,
            paneID: session.paneToken(for: pane),
            selection: selectionSurface?.readSelection() ?? "",
            socket: socketProvider()
        )
    }

    /// A session-free `CommandContext` (an emptied window, or none open): every `{AGT_SESSION_*}`/
    /// `{AGT_WORKSPACE_*}` token and the selection resolve empty, window id/name come from the frontmost
    /// window if any, and the socket lets a launcher chord reach `agtermctl` for a fresh session.
    private func sessionlessContext() -> CommandContext {
        let windowID = library.activeWindowID
        return CommandContext(windowID: windowID?.uuidString ?? "", windowName: library.windowName(for: windowID),
                              socket: socketProvider())
    }

    /// Spawn the expanded command as a detached `/bin/sh -c`, exporting `$AGT_*` over the app environment and
    /// running in `cwd` (nil for a sessionless launch, which inherits the app's). `PATH` is widened first
    /// (`CommandPath`): the app's own is launchd's, and `sh -c` runs no profile, so a bare `agtermctl` would
    /// exit 127. stderr goes to a temp file the failure report reads; a clean exit reports nothing.
    private func spawn(_ command: CustomCommand, context: CommandContext, cwd: String?) {
        let line = context.expand(command.command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        var environment = ProcessInfo.processInfo.environment.merging(context.environment()) { _, new in new }
        environment["PATH"] = CommandPath.widened(environment["PATH"],
                                                  bundledCLIDirectory: CLIInstaller.bundledTool?
                                                      .deletingLastPathComponent().path)
        process.environment = environment
        // fire-and-forget: pin stdin and stdout to /dev/null rather than inherit the app's fds, which vary by
        // launch. stderr is captured instead: it carries the one line that says why a command failed.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let capture = StderrFile()
        process.standardError = capture?.handle ?? FileHandle.nullDevice
        if capture == nil {
            logger.error("custom command \"\(command.name, privacy: .public)\": stderr capture unavailable")
        }
        if let cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        let name = command.name
        let sessionID = context.sessionID
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            // read and remove the file whatever the status, or a successful command leaks one per run.
            let detail = capture.map { CommandFailure.detail(fromTail: $0.consume()) } ?? nil
            guard status != 0 else { return }
            // the handler fires on an arbitrary queue; hop to the main actor to post.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.report(name: name, reason: "exit \(status)", detail: detail, sessionID: sessionID)
                }
            }
        }
        do {
            try process.run()
            usage.record(command)
        } catch {
            _ = capture?.consume()
            logger.error("custom command \"\(name, privacy: .public)\" failed to spawn: \(error.localizedDescription, privacy: .public)")
            // a command that never started has no exit status and no output of its own, so the launch error
            // is the whole diagnosis.
            report(name: name, reason: error.localizedDescription, detail: nil, sessionID: sessionID)
        }
    }

    /// Surface a failed command: the macOS banner as before, plus a panel over the session it fired in. The
    /// banner obeys the notifications setting, so with banners off the panel is the only thing the user sees.
    /// A sessionless launch and a session that has since closed have nowhere to put one.
    private func report(name: String, reason: String, detail: String?, sessionID: String) {
        NotificationManager.shared.notifyCommandFailure(name: name, detail: reason)
        guard let failureHud, !sessionID.isEmpty else { return }
        guard failureHud.open(sessionID, CommandFailure.message(name: name, reason: reason), detail) else {
            logger.notice("custom command \"\(name, privacy: .public)\" failed (\(reason, privacy: .public)); no panel: the session is gone or a program overlay holds the slot")
            return
        }
    }
}
