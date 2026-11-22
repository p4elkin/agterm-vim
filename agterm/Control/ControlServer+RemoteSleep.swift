import AppKit
import agtermCore

/// Which remote rows are on screen, the sleep timer, and the wake when a row comes back into view.
extension ControlServer {
    static let sleepPolicyInterval: TimeInterval = 60

    /// The production `windowOnScreen`: the window is visible, not minimized, in an app that is not hidden.
    static func windowIsOnScreen(_ id: UUID) -> Bool {
        guard let window = WindowRegistry.shared.window(for: id) else { return false }
        return window.isVisible && !window.isMiniaturized && !NSApp.isHidden
    }

    /// The rows window `id` shows: its selection while the window is on screen, and its zoom target and dashboard members
    /// whatever the window state, since those mounts bypass the deck gate and a slept one would leave a blank tile.
    func onScreenRows(inWindow id: UUID, store: AppStore) -> Set<UUID> {
        var rows: Set<UUID> = []
        if windowOnScreen(id), let selected = store.selectedSessionID { rows.insert(selected) }
        if case .session(let zoomed, _)? = TerminalZoomRegistry.shared.controller(for: id)?.target { rows.insert(zoomed) }
        rows.formUnion(DashboardControllerRegistry.shared.controller(for: id)?.members.map(\.session) ?? [])
        return rows
    }

    /// Runs on every remote tick: on-screen edges for every remote row, then the sleep policy at most once a minute.
    func tickRemoteSleep() {
        let now = hudClock()
        var candidates: [(store: AppStore, row: RemoteSleepPolicy.Candidate)] = []
        for id in library.openIDs() {
            guard let store = library.store(for: id) else { continue }
            let shown = onScreenRows(inWindow: id, store: store)
            for session in store.workspaces.flatMap(\.sessions) where session.remoteHost != nil && session.content == .terminal {
                if shown.contains(session.id) {
                    session.offScreenSince = nil
                    if session.asleep { store.wakeRemoteRow(session.id, reason: .shown, onScreen: true, now: now) }
                } else if session.offScreenSince == nil {
                    session.offScreenSince = now
                }
                candidates.append((store, RemoteSleepPolicy.Candidate(id: session.id, eligible: session.sleepEligible,
                                                                      asleep: session.asleep,
                                                                      offScreenSince: session.offScreenSince)))
            }
        }
        if let last = lastSleepPolicyRun, now.timeIntervalSince(last) < Self.sleepPolicyInterval { return }
        lastSleepPolicyRun = now
        let due = Set(RemoteSleepPolicy.rowsToSleep(rows: candidates.map(\.row), now: now,
                                                    after: settingsModel.settings.effectiveRemoteSleepAfterMinutes))
        for candidate in candidates where due.contains(candidate.row.id) {
            candidate.store.sleepRemoteRow(candidate.row.id, reason: .timer, now: now)
        }
    }

    /// windowBecameVisible wakes what window `id` shows now, after a window opens or deminiaturizes, or the app unhides.
    func windowBecameVisible(_ id: UUID) {
        guard let store = library.store(for: id) else { return }
        let shown = onScreenRows(inWindow: id, store: store)
        for row in shown { store.session(withID: row)?.offScreenSince = nil }
        store.wakeShown(shown, now: hudClock())
    }

    func appBecameVisible() {
        library.openIDs().forEach(windowBecameVisible)
    }

    // both re-check every window rather than read the notification's window: a payload carried into the main actor
    // fails Swift 6 Release WMO
    func observeWindowVisibility() {
        guard visibilityObservers.isEmpty else { return }
        let shown: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameVisible() }
        }
        let attached: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.observeRegisteredWindows()
                self?.appBecameVisible()
            }
        }
        visibilityObservers = [
            // a nil queue runs on the registering main thread, so an opened window's asleep selection wakes before it renders
            NotificationCenter.default.addObserver(forName: .agtermWindowAttachmentChanged, object: nil, queue: nil, using: attached),
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main,
                                                   using: shown),
            NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main,
                                                   using: shown),
        ]
    }

    /// observeRegisteredWindows keeps one `isVisible` observation per registered window: a window registers from
    /// `viewDidMoveToWindow`, often before it is visible, and its selection would otherwise wait for the tick.
    func observeRegisteredWindows() {
        let registered = Dictionary(library.openIDs().compactMap { id in WindowRegistry.shared.window(for: id).map { (id, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        windowVisibilityObservations = windowVisibilityObservations.filter { registered[$0.key] === $0.value.window }
        for (id, window) in registered where windowVisibilityObservations[id] == nil {
            let observation = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                MainActor.assumeIsolated { self?.windowBecameVisible(id) }
            }
            windowVisibilityObservations[id] = WindowVisibilityObservation(window: window, observation: observation)
        }
    }

    /// wakeZoomTarget wakes the row a window's zoom now targets, before its host mounts.
    func wakeZoomTarget(inWindow id: UUID) {
        guard case .session(let row, _)? = TerminalZoomRegistry.shared.controller(for: id)?.target else { return }
        library.store(forSession: row)?.wakeShown([row], now: hudClock())
    }
}

/// WindowVisibilityObservation is one registered window's `isVisible` observation.
struct WindowVisibilityObservation {
    weak var window: NSWindow?
    let observation: NSKeyValueObservation
}
