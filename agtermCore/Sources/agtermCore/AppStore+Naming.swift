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

    /// listLabel names a session in a list that drops the tree: `parent › child` for a companion. The
    /// sidebar tree, rename and Copy Name keep the bare `displayName`.
    public func listLabel(for session: Session) -> String {
        guard let parent = parent(of: session) else { return session.displayName }
        return "\(parent.displayName) › \(session.displayName)"
    }

    /// listOrdered sorts `sessions` A-Z by label for a flat list, each parent followed by its companions in
    /// input order, wherever they sit in the input; a companion listed without its parent sorts on its own label.
    public func listOrdered(_ sessions: [Session]) -> [Session] {
        let present = Set(sessions.map(\.id))
        var groups: [(label: String, members: [Session])] = []
        var groupOfParent: [UUID: Int] = [:]
        for session in sessions where session.parentID.map(present.contains) != true {
            groupOfParent[session.id] = groups.count
            groups.append((listLabel(for: session), [session]))
        }
        for session in sessions {
            guard let parentID = session.parentID, let group = groupOfParent[parentID] else { continue }
            groups[group].members.append(session)
        }
        return groups.enumerated().sorted { lhs, rhs in
            let order = lhs.element.label.localizedCaseInsensitiveCompare(rhs.element.label)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.flatMap(\.element.members)
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
