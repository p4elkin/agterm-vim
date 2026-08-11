import Foundation

/// Which zmx sessions a teardown ends, and which it must leave alone. Pure, because this is the one rule in
/// the wrapping that can destroy a live agent: the app target owns only the `zmx kill` that follows.
public enum ZmxLifecycle {
    /// What actually went away.
    public enum Close: Sendable, Equatable {
        /// The whole row, both panes, for good.
        case row
        /// The right pane only; the row survives as a single pane.
        case split
        /// ⚠️ A window closed, which ends NOTHING. The window keeps its session ids in `windows/<id>.json`
        /// and reopens with them, so ending their sessions would kill every agent in the window on ⌘W.
        /// `agterm-zmx-sync` records that mistake in its own header; it is the reason this case exists at all
        /// rather than being an absent call.
        case window
    }

    /// A row as the model knows it while it is being torn down.
    public struct Row: Equatable, Sendable {
        public let sessionID: UUID
        /// `Session.initialCommand`. nil or blank means the left pane runs a login shell, which is exactly the
        /// pane `ZmxWrap` wraps — same blank-is-none reading.
        public let pinnedCommand: String?
        public let keepShellOpen: Bool
        /// `Session.hasSplit`: whether the right pane's shell exists. A split never carries a pinned command,
        /// so its existence is the whole test.
        public let hasSplit: Bool

        public init(sessionID: UUID, pinnedCommand: String?, keepShellOpen: Bool, hasSplit: Bool) {
            self.sessionID = sessionID
            self.pinnedCommand = pinnedCommand
            self.keepShellOpen = keepShellOpen
            self.hasSplit = hasSplit
        }
    }

    /// The zmx sessions this row owns, left pane first. Empty for a row `ZmxWrap` would not have wrapped, so
    /// a command row that never had a daemon is never killed by name.
    public static func ownedKeys(_ row: Row) -> [String] {
        var keys: [String] = []
        let pinned = row.pinnedCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if pinned.isEmpty || row.keepShellOpen {
            keys.append(ZmxSessionKey.key(sessionID: row.sessionID, isSplit: false))
        }
        if row.hasSplit { keys.append(ZmxSessionKey.key(sessionID: row.sessionID, isSplit: true)) }
        return keys
    }

    /// The keys `close` must end.
    public static func keysToEnd(_ row: Row, close: Close) -> [String] {
        switch close {
        case .window: []
        case .row: ownedKeys(row)
        case .split: row.hasSplit ? [ZmxSessionKey.key(sessionID: row.sessionID, isSplit: true)] : []
        }
    }
}

/// The zmx effects a close or a rename performs, injected into `AppStore` so the decision above stays
/// host-free and the subprocess stays in the app target. A nil sink does nothing, which is what a test and an
/// instance that wrapped nothing both want.
@MainActor
public struct ZmxSessionSink {
    /// End the session named `key`, and every client attached to it.
    public var end: (_ key: String) -> Void
    /// Write `name` into the session's `agterm_name` label. zmx has no rename, so the label is the only thing
    /// that carries a renamed row into `zmx list` and the pick list.
    public var label: (_ key: String, _ name: String) -> Void

    public init(end: @escaping (_ key: String) -> Void, label: @escaping (_ key: String, _ name: String) -> Void) {
        self.end = end
        self.label = label
    }
}

extension AppStore {
    /// The row `ZmxLifecycle` reads, built from the live session.
    func zmxRow(_ session: Session) -> ZmxLifecycle.Row {
        ZmxLifecycle.Row(sessionID: session.id, pinnedCommand: session.initialCommand,
                         keepShellOpen: session.keepShellOpen, hasSplit: session.hasSplit)
    }

    /// End the zmx sessions a teardown owns. Every caller is a place the row or its split really went away;
    /// ⚠️ no window-close path may call this at all, see `ZmxLifecycle.Close.window`.
    func endZmxSessions(_ session: Session, close: ZmxLifecycle.Close) {
        guard let zmx else { return }
        for key in ZmxLifecycle.keysToEnd(zmxRow(session), close: close) { zmx.end(key) }
    }
}
