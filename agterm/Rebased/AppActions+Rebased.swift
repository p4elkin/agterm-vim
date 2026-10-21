import AppKit

@MainActor
enum RebasedToggleOutcome: Equatable {
    case hidden, shown, opened, closed, refused(String)
}

extension AppActions {
    @discardableResult
    func toggleRebasedOverlay(session target: UUID? = nil) -> RebasedToggleOutcome {
        guard let store = target.flatMap({ library.store(forSession: $0) }) ?? store,
              let session = target.flatMap({ store.session(withID: $0) }) ?? store.activeSession else {
            return .refused("no active session")
        }
        if let placement = session.rebasedPlacement {
            // Hiding a failed overlay would keep its slot with no way back but ⌘W; closing it makes the next
            // press the retry.
            if case .failed = placement.overlay.state {
                guard store.closeRebasedOverlay(session.id, id: placement.overlay.id) else { return .refused("no Rebased overlay in this session") }
                return .closed
            }
            let hidden = !session.rebasedHidden
            guard store.setRebasedHidden(session.id, id: placement.overlay.id, hidden) else { return .refused("no Rebased overlay in this session") }
            return hidden ? .hidden : .shown
        }
        switch RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: nil, sizePercent: nil) {
        case .success: return .opened
        case .failure(let refusal): return .refused(refusal.message)
        }
    }

    /// rebasedSlotHidden moves the IDE window with its slot bit, whichever route flipped it: the Rebased toggle,
    /// `toggle_overlay`, `session overlay hide|show|toggle`, the menu or the title-bar button.
    func rebasedSlotHidden(session id: UUID, overlay: UUID, hidden: Bool) {
        guard hidden else {
            RebasedHost.shared.show(overlay: overlay, focusIfFocusedPane: true)
            return
        }
        RebasedHost.shared.hide(overlay: overlay)
        if let store = library.store(forSession: id), store.selectedSessionID == id,
           let session = store.session(withID: id) { rebasedRefocus(session) }
    }

    func performRebasedToggle(session: UUID? = nil) {
        if case .refused = toggleRebasedOverlay(session: session) { NSSound.beep() }
    }
}
