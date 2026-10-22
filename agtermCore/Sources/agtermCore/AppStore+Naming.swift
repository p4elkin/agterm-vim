import Foundation

// MARK: - Naming

extension AppStore {
    /// Sets a session's custom name, with a blank value restoring its automatic display name. Returns
    /// whether it CHANGED. Viewers of the session hear the new name; on an attached row the name belongs to
    /// the origin, so it is shown here at once and stays pending until the origin echoes it.
    /// A name over `Session.nameByteLimit` is refused and changes nothing.
    @discardableResult
    public func renameSession(_ sessionID: UUID, to name: String) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        // customName feeds {AGT_SESSION_NAME}; see TerminalText.
        let renamed = TerminalText.sanitized(name).trimmedOrNil
        guard !Session.nameTooLong(renamed), session.customName != renamed else { return false }
        session.customName = renamed
        presentationHub?.publish(.name(renamed), session: sessionID)
        if session.remotePresentation != nil {
            session.remotePresentation?.namePending = true
            session.remotePresentation?.namesInFlight.append(renamed)
            onRemoteSessionRenamed?(sessionID, renamed)
        }
        scheduleTreeChanged()
        save()
        return true
    }

    /// A viewer renamed the session over its presentation stream; nil clears the name. A rename that changes
    /// nothing is echoed all the same, since the sender holds its rename pending until it hears the name
    /// back. Returns whether the name changed.
    @discardableResult
    public func renameFromViewer(_ sessionID: UUID, to name: String?) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if renameSession(sessionID, to: name ?? "") { return true }
        presentationHub?.publish(.name(session.customName), session: sessionID)
        return false
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

extension Session {
    /// Largest accepted custom name, in UTF-8 BYTES. The name rides every presentation snapshot and `name`
    /// frame, so one too large for `PresentationCodec.maxFrameBytes` would end the stream on every reconnect.
    public nonisolated static let nameByteLimit = 1024

    /// Whether a name, already sanitized and trimmed, is over `nameByteLimit`.
    public nonisolated static func nameTooLong(_ name: String?) -> Bool {
        (name?.utf8.count ?? 0) > nameByteLimit
    }

    /// The error a control request carrying an over-long name gets, nil when `raw` fits.
    public static func nameLimitError(_ raw: String?) -> String? {
        guard nameTooLong(raw.flatMap { TerminalText.sanitized($0).trimmedOrNil }) else { return nil }
        return "session name must be at most \(nameByteLimit) UTF-8 bytes"
    }
}
