import Foundation

extension AppStore {
    /// Up to `limit` most-recently-used session ids across all workspaces, most-recent first, skipping
    /// stale/closed ids (so fewer than `limit` when fewer qualify). Read by the `dashboard --mru` open to
    /// populate the grid from the window's recent sessions.
    public func recentSessions(limit: Int) -> [UUID] {
        sessionRecency.top(limit, in: Set(workspaces.flatMap { $0.sessions.map(\.id) }))
    }

    /// The recent-session navigation candidates shared by the title-bar popover and Dock menu: most-recent
    /// first, limited to the visible navigation scope, with the current session removed (selecting it would
    /// not navigate anywhere).
    public func navigableRecentSessions(limit: Int) -> [UUID] {
        var valid = Set(navigableSessions.map(\.id))
        if let activeID = activeSession?.id { valid.remove(activeID) }
        return sessionRecency.top(limit, in: valid)
    }

    /// `navigableRecentSessions(limit:)` shaped for the control tree's `sessionRecency`. Passing the stack's
    /// own bound leaves the wire list UNCAPPED, unlike the popover's `SessionSwitcher.maxCandidates`, so a
    /// consumer picks its own count.
    public func controlSessionRecency() -> [String]? {
        let ids = navigableRecentSessions(limit: sessionRecency.limit).map(\.uuidString)
        return ids.isEmpty ? nil : ids
    }
}
