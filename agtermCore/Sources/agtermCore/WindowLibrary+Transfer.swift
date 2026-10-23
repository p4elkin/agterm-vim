import Foundation

/// The workspace a session move lands in.
public enum TransferWorkspaceTarget: Equatable, Sendable {
    /// A workspace id, `active` or id prefix in the destination window; a new window has none.
    case id(String)
    /// The destination's workspace with this exact name, created when missing.
    case name(String)
    /// `.name` of the first moved session's workspace, in tree order.
    case none
}

/// A transfer that landed. `needsOpen` marks a closed destination the move loaded, which the app still shows.
public struct TransferResult: Equatable, Sendable {
    public let windowID: UUID
    public let sessionIDs: [UUID]
    public let needsOpen: Bool

    public init(windowID: UUID, sessionIDs: [UUID], needsOpen: Bool) {
        self.windowID = windowID
        self.sessionIDs = sessionIDs
        self.needsOpen = needsOpen
    }

    /// `id` is the destination window, `affected` the moved session count.
    public var controlResult: ControlResult {
        ControlResult(id: windowID.uuidString, affected: sessionIDs.count)
    }
}

/// Where an attach put the moved sessions, kept so a failed destination save can take exactly that back.
@MainActor
private struct TransferLanding {
    enum Kind { case new, open, loaded }

    let windowID: UUID
    let store: AppStore
    let kind: Kind
    var workspaceID: UUID?
    var createdWorkspace = false
    var previousSelection: UUID?
}

extension WindowLibrary {
    /// Moves a workspace and its live sessions to another window. The destination saves before the source
    /// lets go, so a crash in between leaves a duplicate row rather than a pane no window file claims.
    public func transferWorkspace(_ workspaceID: UUID, from source: UUID, to destination: TransferDestination,
                                  windowName: String? = nil) -> Result<TransferResult, TransferRefusal> {
        guard let sourceStore = stores[source] else { return .failure(Self.missing("window", source)) }
        if let refusal = destinationRefusal(destination, source: source) { return .failure(refusal) }
        guard let workspace = sourceStore.workspaces.first(where: { $0.id == workspaceID }) else {
            return .failure(Self.missing("workspace", workspaceID))
        }
        if let message = sourceStore.workspaceTransferRefusal(workspaceID) { return .failure(TransferRefusal(message)) }
        if let refusal = Self.survivalRefusal(workspace.sessions) { return .failure(refusal) }
        let active = sourceStore.selectedSessionID.flatMap { id in workspace.sessions.contains { $0.id == id } ? id : nil }
        let selecting = active ?? workspace.sessions.first?.id
        let landing: TransferLanding
        switch destination {
        case .new:
            let window = newWindow(name: windowName ?? workspace.name, seed: workspace, selecting: selecting)
            landing = TransferLanding(windowID: window.id, store: window.store, kind: .new)
        case .window(let id):
            guard case let (store, kind)? = destinationStore(id) else { return .failure(Self.missing("window", id)) }
            landing = TransferLanding(windowID: id, store: store, kind: kind, workspaceID: workspaceID,
                                      createdWorkspace: true, previousSelection: store.selectedSessionID)
            store.attachWorkspace(workspace, selecting: selecting)
        }
        return land(landing, sessionIDs: workspace.sessions.map(\.id), from: sourceStore) { $0.detachWorkspace(workspaceID) }
    }

    /// Moves sessions, in tree order, into one workspace of another window; the workspaces they leave stay.
    public func transferSessions(_ sessionIDs: [UUID], from source: UUID, to destination: TransferDestination,
                                 workspace target: TransferWorkspaceTarget,
                                 windowName: String? = nil) -> Result<TransferResult, TransferRefusal> {
        guard let sourceStore = stores[source] else { return .failure(Self.missing("window", source)) }
        if let refusal = destinationRefusal(destination, source: source) { return .failure(refusal) }
        guard !sessionIDs.isEmpty else { return .failure(TransferRefusal("no sessions to move")) }
        if let unknown = sessionIDs.first(where: { sourceStore.session(withID: $0) == nil }) {
            return .failure(Self.missing("session", unknown))
        }
        let sessions = sourceStore.orderedSessionIDs(matching: Set(sessionIDs)).compactMap(sourceStore.session(withID:))
        if let refusal = Self.survivalRefusal(sessions) { return .failure(refusal) }
        let targetID: UUID?
        let targetName: String
        switch target {
        case .id(let raw):
            guard case .window(let id) = destination else {
                return .failure(TransferRefusal("a new window has no workspace ids; use --workspace-name"))
            }
            switch resolveWorkspace(raw, in: id) {
            case .success(let resolved): targetID = resolved
            case .failure(let refusal): return .failure(refusal)
            }
            targetName = ""
        case .name(let name):
            // trimmed like `AppStore.workspace(named:)`, or " build " creates a second workspace beside `build`
            guard let trimmed = TerminalText.sanitized(name).trimmedOrNil else {
                return .failure(TransferRefusal("blank workspace name"))
            }
            (targetID, targetName) = (nil, trimmed)
        case .none:
            (targetID, targetName) = (nil, sourceStore.workspace(forSession: sessions[0].id)?.name ?? "")
        }
        let ids = sessions.map(\.id)
        let landing: TransferLanding
        switch destination {
        case .new:
            let window = newWindow(name: windowName ?? targetName, seed: Workspace(name: targetName, sessions: sessions),
                                   selecting: ids.first)
            landing = TransferLanding(windowID: window.id, store: window.store, kind: .new)
        case .window(let id):
            guard case let (store, kind)? = destinationStore(id) else { return .failure(Self.missing("window", id)) }
            var attached = TransferLanding(windowID: id, store: store, kind: kind, previousSelection: store.selectedSessionID)
            if let existing = targetID ?? store.workspace(named: targetName)?.id {
                // `attachSessions(_:toWorkspace:)` ignores an unknown id, and the source would then drop the sessions
                guard store.workspaces.contains(where: { $0.id == existing }) else {
                    if kind == .loaded { closeWindow(id) }
                    return .failure(Self.missing("workspace", existing))
                }
                store.attachSessions(sessions, toWorkspace: existing)
                attached.workspaceID = existing
            } else {
                attached.workspaceID = store.attachSessions(sessions, toNewWorkspaceNamed: targetName)
                attached.createdWorkspace = true
            }
            landing = attached
        }
        return land(landing, sessionIDs: ids, from: sourceStore) { $0.detachSessions(ids) }
    }

    // MARK: - Steps

    private func land(_ landing: TransferLanding, sessionIDs: [UUID], from sourceStore: AppStore,
                      detach: (AppStore) -> Void) -> Result<TransferResult, TransferRefusal> {
        guard landing.store.saveChecked() else {
            withdraw(landing, sessionIDs: sessionIDs)
            return .failure(TransferRefusal("destination save failed"))
        }
        if landing.kind == .new {
            frontmostWindowID = landing.windowID
            // no rollback on failure: the window file is saved, and a rollback would orphan it with the
            // workspace inside; retryUnsavedIndex and the launch stray-file claim cover a missing entry
            saveIndex()
        }
        sourceStore.releaseForTransfer(sessionIDs)
        detach(sourceStore)
        sourceStore.save()
        return .success(TransferResult(windowID: landing.windowID, sessionIDs: sessionIDs, needsOpen: landing.kind == .loaded))
    }

    private func withdraw(_ landing: TransferLanding, sessionIDs: [UUID]) {
        if landing.kind == .new { return dropUnsavedWindow(landing.windowID) }
        landing.store.withdrawTransferred(sessionIDs: sessionIDs, workspaceID: landing.workspaceID,
                                          createdWorkspace: landing.createdWorkspace,
                                          previousSelection: landing.previousSelection)
        // its sessionClosed events balance the sessionCreated ones loadStore emitted
        if landing.kind == .loaded { closeWindow(landing.windowID) }
    }

    private func destinationStore(_ id: UUID) -> (AppStore, TransferLanding.Kind)? {
        if let store = stores[id] { return (store, .open) }
        return loadStore(for: id).map { ($0, .loaded) }
    }

    private func destinationRefusal(_ destination: TransferDestination, source: UUID) -> TransferRefusal? {
        guard case .window(let id) = destination else { return nil }
        if id == source { return TransferRefusal("same window") }
        return windows.contains { $0.id == id } ? nil : Self.missing("window", id)
    }

    /// Resolves against a closed window's file, so a refusal never loads the window.
    private func resolveWorkspace(_ raw: String, in windowID: UUID) -> Result<UUID, TransferRefusal> {
        let candidates: [UUID]
        let active: UUID?
        if let store = stores[windowID] {
            candidates = store.workspaces.map(\.id)
            active = store.currentWorkspaceID
        } else {
            let snapshot = closedSnapshot(for: windowID)
            candidates = snapshot.workspaces.map(\.id)
            active = snapshot.workspaces.first { $0.sessions.contains { $0.id == snapshot.selectedSessionID } }?.id
        }
        let resolution = ControlResolve.resolve(raw, candidates: candidates, active: active)
        guard case .resolved(let id) = resolution else {
            return .failure(TransferRefusal(ControlResolve.errorMessage(noun: "workspace", target: raw, resolution: resolution)))
        }
        return .success(id)
    }

    private static func survivalRefusal(_ sessions: [Session]) -> TransferRefusal? {
        sessions.first { !$0.canSurviveTransfer }.map { TransferRefusal("pane not zmx-backed: \($0.id.uuidString)") }
    }

    private static func missing(_ noun: String, _ id: UUID) -> TransferRefusal {
        TransferRefusal(ControlResolve.notFoundMessage(noun: noun, target: id.uuidString))
    }
}
