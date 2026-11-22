import Foundation

/// A sleeping remote row loses only its pane surfaces, released without waiting on their threads; a wake renews its lines.
extension AppStore {
    /// sleepRemoteRow releases row `id`'s panes; true when the row is asleep afterwards, false when it is not eligible.
    @discardableResult
    public func sleepRemoteRow(_ id: UUID, reason: RemoteSleepReason, now: Date = Date()) -> Bool {
        guard let session = session(withID: id) else { return false }
        if session.asleep { return true }
        guard session.sleepEligible else { return false }
        session.clearSearch()
        // a hidden split a wake did not build again keeps the mark of the sleep that released it
        session.splitReleasedAsleep = session.splitSurface != nil || session.splitReleasedAsleep
        session.surface?.releaseForSleep()
        session.splitSurface?.releaseForSleep()
        session.surface = nil
        session.splitSurface = nil
        session.primaryRespawns &+= 1
        // what a reconnect would have cleared: nothing retries an asleep row, and its wake attaches afresh
        for pane in [session.paneIdentity] + [session.splitPaneIdentity].compactMap({ $0 }) {
            ZmxLeadBook.shared.forget(pane: pane)
            RemoteReconnectBook.shared.cancel(pane: pane)
            session.remotePresentation?.heldPanes.remove(pane)
        }
        if session.remotePresentation?.rowState == .disconnected { setRemoteRowState(.attached, forSession: id) }
        session.asleep = true
        session.asleepSince = now
        emitControlEvent(.sessionSlept, workspace: workspace(forSession: id)?.id, session: id,
                         payload: ControlEventPayload(name: session.displayName, reason: reason.rawValue))
        scheduleTreeChanged()
        return true
    }

    /// wakeRemoteRow renews row `id`'s lines; false, leaving it asleep, with no renewal, as a nil line spawns a local shell.
    @discardableResult
    public func wakeRemoteRow(_ id: UUID, reason: RemoteSleepReason, onScreen: Bool, now: Date = Date()) -> Bool {
        guard let session = session(withID: id) else { return false }
        guard session.asleep else { return true }
        guard let renew = onRowWake?() else { return false }
        session.asleep = false
        session.asleepSince = nil
        session.offScreenSince = onScreen ? nil : now
        renew(session)
        emitControlEvent(.sessionWoke, workspace: workspace(forSession: id)?.id, session: id,
                         payload: ControlEventPayload(name: session.displayName, reason: reason.rawValue))
        scheduleTreeChanged()
        return true
    }

    /// wakeShown wakes each named row that is asleep, as shown: a selection, a zoom target or a dashboard member about
    /// to mount.
    public func wakeShown(_ ids: some Sequence<UUID>, now: Date = Date()) {
        for id in ids where session(withID: id)?.asleep == true {
            wakeRemoteRow(id, reason: .shown, onScreen: true, now: now)
        }
    }
}
