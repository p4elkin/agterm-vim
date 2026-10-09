import AppKit

extension AppActions {
    /// Opens Rebased on a session's repository, or closes it there; over a program or a page the slot is taken,
    /// so it refuses like `session overlay open`. `session` is the one owning the key IDE window, nil for the
    /// active session.
    func toggleRebasedOverlay(session target: UUID? = nil) {
        guard let store = target.flatMap({ library.store(forSession: $0) }) ?? store,
              let session = target.flatMap({ store.session(withID: $0) }) ?? store.activeSession else { return }
        if let placement = session.rebasedPlacement {
            store.closeRebasedOverlay(session.id, id: placement.overlay.id)
        } else if case .failure = RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: nil, sizePercent: nil) {
            NSSound.beep()
        }
    }
}
