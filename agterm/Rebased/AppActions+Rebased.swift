import AppKit

@MainActor
enum RebasedToggleOutcome: Equatable {
    case hidden, shown, opened, refused(String)
}

extension AppActions {
    @discardableResult
    func toggleRebasedOverlay(session target: UUID? = nil) -> RebasedToggleOutcome {
        guard let store = target.flatMap({ library.store(forSession: $0) }) ?? store,
              let session = target.flatMap({ store.session(withID: $0) }) ?? store.activeSession else {
            return .refused("no active session")
        }
        if let placement = session.rebasedPlacement {
            let hidden = !placement.overlay.hidden
            guard store.setRebasedHidden(session.id, id: placement.overlay.id, hidden) else { return .refused("no Rebased overlay in this session") }
            if hidden {
                RebasedHost.shared.hide(overlay: placement.overlay.id)
                if store.selectedSessionID == session.id { rebasedRefocus(session) }
                return .hidden
            }
            RebasedHost.shared.show(overlay: placement.overlay.id)
            return .shown
        }
        switch RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: nil, sizePercent: nil) {
        case .success: return .opened
        case .failure(let refusal): return .refused(refusal.message)
        }
    }

    func performRebasedToggle(session: UUID? = nil) {
        if case .refused = toggleRebasedOverlay(session: session) { NSSound.beep() }
    }
}
