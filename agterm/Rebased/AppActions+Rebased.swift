import AppKit

extension AppActions {
    /// Opens Rebased on the active session's repository, or closes it there; over a program or a page the
    /// slot is taken, so it refuses like `session overlay open`.
    func toggleRebasedOverlay() {
        guard let store, let session = store.activeSession else { return }
        if session.rebasedOverlayActive {
            store.closeOverlay(session.id)
        } else if RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: nil, sizePercent: nil) != nil {
            NSSound.beep()
        }
    }
}
