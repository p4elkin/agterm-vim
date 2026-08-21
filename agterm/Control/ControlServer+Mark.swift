import Foundation
import agtermCore

/// `session.mark` (fork only): advance the target session's turn counter and write the visible `TurnMark`
/// into its pane's pty by absolute path.
///
/// ⚠️ The pty write only reaches a pane with no full-screen TUI in it. A pane running an agent is repainted
/// by the agent (and by the zmx client under it) from its own buffer, so these bytes are wiped before the
/// next frame and never enter scrollback. For an agent the mark is echoed by the AGENT instead: the hook
/// takes the number this returns and instructs it to print the line. See `.claude/rules/control-api.md`.
extension ControlServer {
    func markSessionTurn(_ target: String?, window: String?, paneID: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id), let turn = store.markTurn(id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            writeTurnMark(turn, to: session, paneID: paneID)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, count: turn))
        }
    }

    /// The mark goes to the pane the AGENT runs in, resolved from the caller's own `AGTERM_PANE_ID` the way
    /// `session.status` resolves its own. Writing to `session.surface` unconditionally puts an agent's marks
    /// into the other pane of a split — over whatever that shell is showing — while `bookmark go` searches
    /// the focused one and finds nothing. An unknown or absent token falls back to the primary pane, which
    /// is right for the unsplit case the hook cannot distinguish.
    ///
    /// A failed write is not an error: the number still names the turn, and for an agent pane the visible
    /// mark comes from the agent's own reply anyway. An unrealized pane simply has no pty yet.
    private func writeTurnMark(_ turn: Int, to session: Session, paneID: String?) {
        guard let path = (markSurface(of: session, paneID: paneID) as? GhosttySurfaceView)?.ttyName(),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(TurnMark.payload(for: turn).utf8))
    }

    /// `paneRole(forToken:)` reads the token's CURRENT slot, so a promoted split survivor marks the pane it
    /// now occupies rather than the one it was spawned as.
    private func markSurface(of session: Session, paneID: String?) -> (any TerminalSurface)? {
        guard let paneID, let role = session.paneRole(forToken: paneID) else { return session.surface }
        switch role {
        case .left: return session.surface
        case .right: return session.splitSurface
        case .scratch: return session.scratchSurface
        }
    }

    // MARK: - Bookmarks (fork only)

    func addSessionBookmark(_ target: String?, window: String?, turn: Int?, prompt: String) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let resolvedTurn = turn ?? session.turnCounter
            guard resolvedTurn > 0 else {
                return ControlResponse(ok: false, error: "no turn to bookmark: session.mark has not run here")
            }
            // the counter is ephemeral, so a turn it has not reached names nothing in this scrollback.
            guard resolvedTurn <= session.turnCounter else {
                return ControlResponse(ok: false,
                                       error: "turn \(resolvedTurn) has not happened (latest is \(session.turnCounter))")
            }
            let bookmark = library.bookmarks.add(sessionID: id, turn: resolvedTurn, prompt: prompt)
            showBookmarkToast(in: store, session: session, turn: resolvedTurn)
            return ControlResponse(ok: true,
                                   result: ControlResult(id: bookmark.id.uuidString, count: resolvedTurn))
        }
    }

    private static let toastSeconds = 2.5

    /// Best-effort toast through the `session.hud` path. The HUD shares the session's single overlay slot,
    /// so an occupied slot skips it outright — a program would refuse anyway, and `openHud` REPLACES a
    /// caller's panel, which a toast that closes itself seconds later must never evict. No failure here may
    /// fail the add: the bookmark is already stored.
    private func showBookmarkToast(in store: AppStore, session: Session, turn: Int) {
        guard !session.overlayActive else { return }
        let spec = HudSpec(message: "bookmarked \(TurnMark.needle(for: turn))", position: .bottomCenter)
        guard openHud(session.id.uuidString, window: nil, spec: spec).ok else { return }
        let id = session.id
        // close only what is still THIS toast: a caller's hud.open replacing it must outlive the timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastSeconds) { [weak store] in
            guard let store, let session = store.session(withID: id), session.hudSpec == spec else { return }
            store.closeHud(id)
        }
    }

    func listSessionBookmarks(_ target: String?, window: String?, all: Bool) -> ControlResponse {
        if all {
            return ControlResponse(ok: true,
                                   result: ControlResult(bookmarks: bookmarkNodes(library.bookmarks.list())))
        }
        return resolver.resolveSession(target, window: window) { _, id in
            ControlResponse(ok: true,
                            result: ControlResult(bookmarks: bookmarkNodes(library.bookmarks.list(sessionID: id))))
        }
    }

    func removeSessionBookmark(_ target: String?, window: String?, turn: Int) -> ControlResponse {
        resolver.resolveSession(target, window: window) { _, id in
            guard library.bookmarks.remove(sessionID: id, turn: turn) else {
                return ControlResponse(ok: false, error: "no bookmark for turn \(turn)")
            }
            return ControlResponse(ok: true)
        }
    }

    /// Session names resolved once across every open window, so a 50-bookmark `--all` does not walk the
    /// whole tree per row. A closed window's session lists with no name; its bookmarks survive for a later
    /// reopen because only session CLOSE drops them.
    private func bookmarkNodes(_ bookmarks: [Bookmark]) -> [ControlBookmarkNode] {
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: two windows holding one session id is a bug in
        // another subsystem, and a read-only list must not be what turns it into a trap that kills the app.
        let names = Dictionary(library.allOpenSessions().map { ($0.id, $0.displayName) },
                               uniquingKeysWith: { first, _ in first })
        return bookmarks.map { ControlBookmarkNode($0, sessionName: names[$0.sessionID]) }
    }
}
