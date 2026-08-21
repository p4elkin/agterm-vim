import Foundation

/// Parked-row hiding: `hideParked` plus `parkedRevealedWorkspaceIDs`, the per-window pair mirroring
/// `focusEnabled`/`focusedWorkspaceIDs` (see `AppStore+Focus.swift`). The stored fields live on the class.
extension AppStore {
    // `setParked` lives with the hiding that projects over it, not in AppStore.swift.

    /// Sets (or clears) a session's parked mark — the row is kept, whatever agent it held is not — and
    /// persists. Idempotent like `setFlag`: an unchanged value writes nothing, so a repeated `session.park`
    /// costs no save. No-op for an unknown id.
    ///
    /// Deliberately touches nothing but the mark: no selection repair, no focus, no sidebar mode. A parked
    /// row stays selectable and stays where it is, so there is no view a parked session can fall out of.
    public func setParked(_ on: Bool, forSession id: UUID) {
        guard let session = session(withID: id), session.parked != on else { return }
        session.parked = on
        save()
        emitControlEvent(.sessionParked, workspace: workspace(forSession: id)?.id, session: id,
                         payload: ControlEventPayload(name: session.displayName, parked: on))
    }

    /// THE row-visibility predicate — false ONLY when the session is parked, `hideParked` is on, its
    /// workspace is not in the revealed exception set, and it is not the selected session. The one place
    /// this rule is spelled: the outline, `navigableSessions` and every other asker call here rather than
    /// re-deriving it inline. Pure and read-only. The selected-row exemption keeps the row under a visible
    /// pane from vanishing when parked; it leaves the tree on the next selection change.
    public func isRowVisible(_ session: Session) -> Bool {
        guard session.parked, hideParked, session.id != selectedSessionID else { return true }
        guard let owner = workspace(forSession: session.id)?.id else { return false }
        return parkedRevealedWorkspaceIDs.contains(owner)
    }

    /// Applies one `sidebar.parked` mode to this window's `hideParked` flag, leaving the revealed set
    /// alone — the bare-command form. Host-free so the mode-to-flag mapping is unit tested and the control
    /// arm keeps only window resolution.
    public func applyParkedVisibility(_ mode: ControlParkedVisibilityMode) {
        commitParkedHiding(hidden: mode.desiredHidden(current: hideParked),
                           revealed: parkedRevealedWorkspaceIDs)
    }

    /// Applies one mode to a single workspace's membership in the revealed exception set, leaving the flag
    /// alone: `show` marks it revealed, `hide` unmarks, `toggle` flips. Marking is refused for an id naming
    /// no workspace — a phantom member is what broke the focus read-back (see `setFocusMembership`);
    /// unmarking is ungated, so a stale id stays removable.
    public func applyParkedVisibility(_ mode: ControlParkedVisibilityMode, toWorkspace id: UUID) {
        var revealed = parkedRevealedWorkspaceIDs
        // revealed membership is the SHOW state, so the flag polarity helper does not apply here.
        let reveal: Bool
        switch mode {
        case .show: reveal = true
        case .hide: reveal = false
        case .toggle: reveal = !revealed.contains(id)
        }
        if reveal {
            guard workspaces.contains(where: { $0.id == id }) else { return }
            revealed.insert(id)
        } else {
            revealed.remove(id)
        }
        commitParkedHiding(hidden: hideParked, revealed: revealed)
    }

    /// `--workspace all`: clears the exception set and applies the mode everywhere through the flag, so
    /// one call ends a per-workspace patchwork.
    public func applyParkedVisibilityEverywhere(_ mode: ControlParkedVisibilityMode) {
        commitParkedHiding(hidden: mode.desiredHidden(current: hideParked), revealed: [])
    }

    /// The single write point for the hiding pair: skips an unchanged write, so delta-computed callers stay
    /// idempotent and no-op writes never persist. No selection repair, unlike `commitFocus` — the selected
    /// row is exempt from the predicate, so hiding can never move the selection outside the visible set.
    private func commitParkedHiding(hidden: Bool, revealed: Set<UUID>) {
        guard hideParked != hidden || parkedRevealedWorkspaceIDs != revealed else { return }
        hideParked = hidden
        parkedRevealedWorkspaceIDs = revealed
        save()
    }

    /// Restores the hiding pair from a snapshot, PRUNING revealed ids that name no workspace in the
    /// restored tree, like `restoreFocus`. Unlike focus, a set pruned to empty leaves `hideParked` alone:
    /// an empty exception set means "hide everywhere", a normal state rather than an
    /// enabled-but-invisible filter. Called from `restore(from:)` after the tree is rebuilt; writes the
    /// fields directly, since a mutator would `save()` what was just read.
    func restoreParkedHiding(from snapshot: Snapshot) {
        let present = Set(workspaces.map(\.id))
        parkedRevealedWorkspaceIDs = Set(snapshot.parkedRevealedWorkspaceIDs ?? []).intersection(present)
        hideParked = snapshot.hideParked ?? false
    }
}

extension AppStore {
    /// How many of a workspace's rows are parked, nil when none, in the shape `ControlWorkspaceNode` wants.
    /// The FACT, not the drawing: a hidden parked row counts the same as a drawn one, which is what keeps
    /// the count honest while `hideParked` is on.
    public func parkedCount(in workspace: Workspace) -> Int? {
        let parked = workspace.sessions.count { $0.parked }
        return parked > 0 ? parked : nil
    }

    /// Whether this workspace is in the reveal exception set; true-only, and reported independently of
    /// `hideParked` so the set stays legible with hiding off — the same rule `focused` follows.
    func revealsParked(_ workspace: Workspace) -> Bool? {
        parkedRevealedWorkspaceIDs.contains(workspace.id) ? true : nil
    }
}

extension AppStore {
    /// A session's position among the rows the sidebar DRAWS, and how many it draws — the drawn-space twin
    /// of `sessionLocation(ofSession:)`.
    ///
    /// ⚠️ Drag-and-drop needs this because `NSOutlineView` indexes the children it was GIVEN, and those are
    /// filtered by `isRowVisible`. Feeding it a model index and a drawn index in the same arithmetic moved
    /// the wrong row: the two spaces were identical until parked rows could be hidden, so nothing in
    /// `SidebarDrop` had to reconcile them.
    public func visibleSessionLocation(ofSession id: UUID) -> (workspace: UUID, index: Int, count: Int)? {
        guard let workspace = workspace(forSession: id) else { return nil }
        let visible = workspace.sessions.filter(isRowVisible)
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return nil }
        return (workspace.id, index, visible.count)
    }

    /// How many rows the sidebar draws for a workspace; the drawn-space twin of `sessions.count`.
    public func visibleSessionCount(inWorkspace id: UUID) -> Int {
        workspaces.first(where: { $0.id == id })?.sessions.filter(isRowVisible).count ?? 0
    }

    /// Translate a post-removal DRAWN insertion index into the model index `moveSessions(_:toWorkspace:at:)`
    /// wants, with `moved` already taken out of both lists.
    ///
    /// The drop means "put the block where that drawn row is", so the anchor is the drawn row currently at
    /// `drawnDestination` and the answer is its index in the model. Past the last drawn row it appends,
    /// which puts the block after any hidden rows trailing the list — the only choice that keeps a drag to
    /// the bottom of a workspace looking like it landed at the bottom.
    public func modelInsertionIndex(drawnDestination: Int, inWorkspace id: UUID,
                                    excluding moved: Set<UUID>) -> Int {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return drawnDestination }
        let remaining = workspace.sessions.filter { !moved.contains($0.id) }
        let visible = remaining.filter(isRowVisible)
        guard drawnDestination >= 0, drawnDestination < visible.count else { return remaining.count }
        let anchor = visible[drawnDestination]
        return remaining.firstIndex(where: { $0.id == anchor.id }) ?? remaining.count
    }
}
