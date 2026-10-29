import Foundation

extension AppStore {
    /// setOverlaysHidden hides or shows a session's overlays: one pane's, or every program and page of the
    /// session for a nil `pane`. A hidden overlay keeps running and stays addressable. nil on success,
    /// including when nothing changed; `tree.changed` fires only on a change. A page shown on the presenting
    /// Mac is asked to change, and its reported state changes when that Mac answers. A parked IDE that cannot
    /// be seated back is refused last, after every other slot changed.
    @discardableResult
    public func setOverlaysHidden(_ sessionID: UUID, pane: OverlayPane?, hidden: Bool) -> OverlayVisibilityFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        let slots = session.hideableOverlaySlots(pane)
        let pages = session.remotePageSlots(pane)
        guard !slots.isEmpty || !pages.isEmpty else { return session.overlayVisibilityRefusal(pane) }
        let changing = slots.filter { session.slotEffectivelyHidden($0) != hidden }
        var refusal: RebasedOverlayOpenFailure?
        for slot in changing { refusal = setSlotHidden(session, slot: slot, hidden) ?? refusal }
        for page in session.replicaPages where changing.contains(page.pane) { onReplicaPageChanged?(page.page.id) }
        for slot in pages where slot.page?.effectiveHidden != hidden {
            sendRemotePageCommand(sessionID, pane: slot.pane, action: hidden ? .hide : .show)
        }
        return refusal.map(OverlayVisibilityFailure.rebased)
    }

    /// toggleOverlaysHidden hides the scoped overlays when any of them is shown, otherwise shows them all.
    @discardableResult
    public func toggleOverlaysHidden(_ sessionID: UUID, pane: OverlayPane?) -> OverlayVisibilityFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        return setOverlaysHidden(sessionID, pane: pane, hidden: session.anyOverlayShown(pane))
    }

    /// applyOverlayVisibility runs a control `mode` against the scoped overlays.
    @discardableResult
    public func applyOverlayVisibility(_ sessionID: UUID, pane: OverlayPane?,
                                       mode: OverlayVisibilityMode) -> OverlayVisibilityFailure? {
        switch mode {
        case .hide: return setOverlaysHidden(sessionID, pane: pane, hidden: true)
        case .show: return setOverlaysHidden(sessionID, pane: pane, hidden: false)
        case .toggle: return toggleOverlaysHidden(sessionID, pane: pane)
        }
    }

    /// hideHtmlOverlay hides page `id` from its own strip with a page's scope: a pane page hides its pane,
    /// a session-wide page the session's overlays. False once the page left its slot.
    @discardableResult public func hideHtmlOverlay(_ id: UUID) -> Bool {
        guard let slot = htmlOverlaySlot(id) else { return false }
        return setOverlaysHidden(slot.session.id, pane: slot.pane, hidden: true) == nil
    }

    /// setSlotHidden parks an IDE instead of setting its slot's bit, and a show of the slot it left, while that
    /// slot is empty, unparks it; nil unless that unpark is refused.
    @discardableResult
    func setSlotHidden(_ session: Session, slot: OverlayPane?, _ hidden: Bool) -> RebasedOverlayOpenFailure? {
        if session.rebasedPlacement?.pane == slot, session.parkedRebased == nil,
           slot.map({ session.paneOverlay($0)?.rebased != nil }) ?? (session.rebasedOverlay != nil) {
            if hidden { parkRebasedOverlay(session, slot: slot) }
            return nil
        }
        if session.parkedOnly(in: slot) {
            return hidden ? nil : unparkRebasedOverlay(session)
        }
        guard session.slotEffectivelyHidden(slot) != hidden else { return nil }
        session.setOverlayHidden(hidden, slot: slot)
        RebasedOverlayReleases.shared.hiddenChanged(session, slot: slot)
        scheduleTreeChanged()
        return nil
    }

    func hiddenOverlaysNode(_ session: Session) -> [String]? {
        let names = session.hiddenOverlayNames
        return names.isEmpty ? nil : names
    }
}
