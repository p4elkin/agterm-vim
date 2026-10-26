import Foundation

/// Moving sessions to another window's store keeps the same `Session` objects, so their zmx daemons live on.
/// None of these save: the library saves the destination first and the source only after it.
extension AppStore {
    // MARK: - Refusals

    /// Why `workspaceID` cannot leave this window, nil when it can.
    func workspaceTransferRefusal(_ workspaceID: UUID) -> String? {
        let undoTarget = pendingCloseRecords.values.contains { record in
            guard case let .sessions(close) = record else { return false }
            return close.sessions.contains { $0.workspaceID == workspaceID }
        }
        return undoTarget ? "workspace has a pending close" : nil
    }

    // MARK: - Source

    /// Frees every surface of the sessions while they are still here, leaving the primary and split daemons
    /// running. Overlay, scratch, HUD and search state are not carried across windows.
    func releaseForTransfer(_ sessionIDs: [UUID]) {
        for id in sessionIDs {
            guard let session = session(withID: id) else { continue }
            closeOverlay(id)
            closeScratch(id)
            // closeScratch returns early without a surface
            session.scratchActive = false
            session.teardownPaneOverlays()
            session.teardownOverlaySlot()
            session.clearSearch()
            session.surface?.prepareForTransfer()
            session.splitSurface?.prepareForTransfer()
            session.surface = nil
            session.splitSurface = nil
            session.overlaySurface = nil
            session.scratchSurface = nil
        }
    }

    /// Runs only after the destination saved. Unlike `removeWorkspace` nothing is finalized or recorded as
    /// closed, and the panes stay claimed for the launch reap.
    func detachWorkspace(_ workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let workspace = workspaces[index]
        let removingActive = selectedSessionID.map { id in workspace.sessions.contains { $0.id == id } } ?? false
        workspace.sessions.forEach(releaseLeavingSession)
        dropFocusMember(workspaceID)
        workspaces.remove(at: index)
        forgetFreshWorkspace(workspaceID)
        // commitParkedHiding would save
        parkedRevealedWorkspaceIDs.remove(workspaceID)
        workspace.sessions.forEach { removeFromRecency($0.id) }
        if removingActive {
            reselectAfterDetach(workspaceRemovalTarget(at: index))
        } else {
            pruneSidebarSelection()
        }
        scheduleTreeChanged()
    }

    /// The session form of `detachWorkspace`; the workspaces they leave stay, empty or not.
    func detachSessions(_ sessionIDs: [UUID]) {
        let ids = orderedSessionIDs(matching: Set(sessionIDs))
        let leaving = ids.compactMap { id in location(ofSession: id).map { (id: id, location: $0) } }
        guard !leaving.isEmpty else { return }
        let active = selectedSessionID.flatMap { id in leaving.first { $0.id == id }?.location }
        let removedBeforeActive = active.map { active in
            leaving.count { $0.location.workspaceIndex == active.workspaceIndex && $0.location.sessionIndex < active.sessionIndex }
        } ?? 0
        let gone = Set(ids)
        for item in leaving {
            releaseLeavingSession(workspaces[item.location.workspaceIndex].sessions[item.location.sessionIndex])
        }
        for index in workspaces.indices { workspaces[index].sessions.removeAll { gone.contains($0.id) } }
        ids.forEach(removeFromRecency)
        if let active {
            reselectAfterDetach(closeReselectionTarget(after: (workspaceIndex: active.workspaceIndex,
                                                               sessionIndex: active.sessionIndex - removedBeforeActive)))
        } else {
            pruneSidebarSelection()
        }
        scheduleTreeChanged()
    }

    private func reselectAfterDetach(_ target: UUID?) {
        selectedSessionID = target
        replaceSidebarSelection(with: target)
        disableFocusIfSelectionOutsideSet(target)
        // the source window's fallback, not a visit
        recordRecency(appWide: false)
    }

    // MARK: - Destination

    /// No `sessionCreated`: the sessions already exist in another window. The new workspace joins an applied
    /// focus filter like `addWorkspace`'s; selecting it from outside the marked set would switch the filter off.
    func attachWorkspace(_ workspace: Workspace, selecting sessionID: UUID?) {
        workspaces.append(workspace)
        revealNewFocusMember(workspace.id)
        if let sessionID, workspace.sessions.contains(where: { $0.id == sessionID }) { selectAttached(sessionID) }
        scheduleTreeChanged()
    }

    func attachSessions(_ sessions: [Session], toWorkspace workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].sessions.append(contentsOf: sessions)
        if let first = sessions.first { selectAttached(first.id) }
        scheduleTreeChanged()
    }

    /// Creates the workspace without `addWorkspace`, which saves.
    func attachSessions(_ sessions: [Session], toNewWorkspaceNamed name: String) -> UUID {
        let workspace = Workspace(name: TerminalText.sanitized(name), sessions: sessions)
        attachWorkspace(workspace, selecting: sessions.first?.id)
        return workspace.id
    }

    /// Takes back exactly what an attach added after the destination failed to save. The sessions are still
    /// live in the source, so nothing is released, closed or finalized. `previousSelection` is the selection
    /// read before the attach; restoring it fires `sessionSelected` like any other change.
    func withdrawTransferred(sessionIDs: [UUID], workspaceID: UUID?, createdWorkspace: Bool, previousSelection: UUID?) {
        let gone = Set(sessionIDs)
        if createdWorkspace, let workspaceID {
            workspaces.removeAll { $0.id == workspaceID }
            forgetFreshWorkspace(workspaceID)
            dropFocusMember(workspaceID)
        }
        for index in workspaces.indices { workspaces[index].sessions.removeAll { gone.contains($0.id) } }
        sessionIDs.forEach(removeFromRecency)
        if selectedSessionID != previousSelection {
            selectedSessionID = previousSelection
            replaceSidebarSelection(with: previousSelection)
        } else {
            pruneSidebarSelection()
        }
        scheduleTreeChanged()
    }

    private func selectAttached(_ sessionID: UUID) {
        selectedSessionID = sessionID
        replaceSidebarSelection(with: sessionID)
        disableFocusIfSelectionOutsideSet(sessionID)
        recordRecency()
    }
}
