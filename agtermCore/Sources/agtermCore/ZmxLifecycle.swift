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
        /// ⚠️ The pane's own process exited, which ends NOTHING. Under wrapping that process IS the zmx
        /// client, and a client exits for two reasons the app cannot tell apart: the session ended (there is
        /// then nothing left to kill) or the user DETACHED from it (killing it would destroy the running
        /// agent they detached to keep). The daemon a detach leaves behind is reattachable by name, and an
        /// abandoned one is reaped at the next launch, so leaking is the recoverable side of this choice.
        case clientExit
    }

    /// A row as the model knows it while it is being torn down: the zmx sessions its two panes actually
    /// attached to, recorded by the surface factory (`Session.zmxPrimaryKey`/`zmxSplitKey`).
    ///
    /// ⚠️ Deliberately NOT the pane roles. Re-deriving `<uuid>-left` from "this is the main pane" is wrong
    /// for a promoted split survivor, which keeps the `-right` session it attached to, and wrong for any row
    /// whose wrap decision differed from what the model can see (`plan.command` versus `initialCommand`).
    public struct Row: Equatable, Sendable {
        public let primaryKey: String?
        public let splitKey: String?

        public init(primaryKey: String?, splitKey: String?) {
            self.primaryKey = primaryKey
            self.splitKey = splitKey
        }
    }

    /// The zmx sessions this row owns, main pane first. Empty for a row no pane of which was ever wrapped.
    public static func ownedKeys(_ row: Row) -> [String] {
        [row.primaryKey, row.splitKey].compactMap { $0 }
    }

    /// The keys `close` must end.
    public static func keysToEnd(_ row: Row, close: Close) -> [String] {
        switch close {
        case .window, .clientExit: []
        case .row: ownedKeys(row)
        case .split: [row.splitKey].compactMap { $0 }
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

extension Session {
    /// The two keys a wrap decision for `role` reads: the one this pane recorded, and the one its sibling
    /// pane holds. One function rather than two field reads at each factory, because swapping them hands a
    /// pane the daemon the pane beside it is already attached to.
    public func zmxKeys(for role: ZmxSessionKey.Role) -> (own: String?, sibling: String?) {
        switch role {
        case .left: (zmxPrimaryKey, zmxSplitKey)
        case .right: (zmxSplitKey, zmxPrimaryKey)
        }
    }
}

extension ZmxLifecycle.Row {
    @MainActor public init(_ session: Session) {
        self.init(primaryKey: session.zmxPrimaryKey, splitKey: session.zmxSplitKey)
    }

    /// The row a closed window's persisted sessions describe, for the delete path that has no live store.
    public init(_ snapshot: SessionSnapshot) {
        self.init(primaryKey: snapshot.zmxPrimaryKey, splitKey: snapshot.zmxSplitKey)
    }
}

extension AppStore {
    /// A pane's surface just wrapped under `key`: the row RECORDS it (see `ZmxLifecycle.Row` for why it is
    /// never re-derived) and the daemon takes the row's display name as its `agterm_name` label.
    ///
    /// Labelling here rather than in `renameSession` alone is what keeps `zmx list` and the pick list
    /// readable for a row nobody ever renamed; it also relabels every wrapped row at each launch, since a
    /// restored pane comes back through the same factories.
    public func recordZmxSession(_ key: String, role: ZmxSessionKey.Role, forSession session: Session) {
        switch role {
        case .left: session.zmxPrimaryKey = key
        case .right: session.zmxSplitKey = key
        }
        zmx?.label(key, session.displayName)
    }

    /// The row `ZmxLifecycle` reads, built from the live session.
    func zmxRow(_ session: Session) -> ZmxLifecycle.Row { ZmxLifecycle.Row(session) }

    /// End the zmx sessions a teardown owns. Every caller is a place the row or its split really went away;
    /// ⚠️ no window-close path may call this at all, see `ZmxLifecycle.Close.window`.
    func endZmxSessions(_ session: Session, close: ZmxLifecycle.Close) {
        guard let zmx else { return }
        for key in ZmxLifecycle.keysToEnd(zmxRow(session), close: close) { zmx.end(key) }
    }
}
