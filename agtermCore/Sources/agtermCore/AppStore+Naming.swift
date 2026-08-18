import Foundation

// MARK: - Naming

extension AppStore {
    /// Sets a session's custom name, with a blank value restoring its automatic display name.
    public func renameSession(_ sessionID: UUID, to name: String) {
        guard let session = session(withID: sessionID) else { return }
        // customName feeds {AGT_SESSION_NAME}; see TerminalText.
        let renamed = TerminalText.sanitized(name).trimmedOrNil
        guard session.customName != renamed else { return }
        session.customName = renamed
        // zmx has no rename, so a renamed row carries its name as the session's `agterm_name` label instead —
        // which is what keeps `zmx list` and the pick list readable after a rename.
        if let zmx {
            for key in ZmxLifecycle.ownedKeys(zmxRow(session)) { zmx.label(key, session.displayName) }
        }
        scheduleTreeChanged()
        save()
    }

    /// Renames a workspace. Blank and same-value names are structural no-ops.
    public func renameWorkspace(_ workspaceID: UUID, to name: String) {
        // the name feeds {AGT_WORKSPACE_NAME}; see TerminalText.
        guard let trimmed = TerminalText.sanitized(name).trimmedOrNil,
              let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].name != trimmed else { return }
        workspaces[index].name = trimmed
        scheduleTreeChanged()
        save()
    }

    /// The name of `workspaceID`; nil when it is gone, and when it is blank — `renameWorkspace` rejects a
    /// blank one, but `AppStore+PendingClose` rebuilds a `Workspace` from a snapshot without that guard.
    public func workspaceName(_ workspaceID: UUID) -> String? {
        workspaces.first(where: { $0.id == workspaceID })?.name.trimmedOrNil
    }
}
