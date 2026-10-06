import AppKit
import OSLog
import agtermCore

private let logger = Logger(subsystem: "com.umputun.agterm", category: "AppActions")

extension AppActions {
    /// The "+" new-session controls: the sidebar row button, its "New Session" item and the footer item. With
    /// a Settings host they create there and never fall back to a local session, which would hide a dead host.
    /// `store` is the control's own window, which gates the action. Returns the remote create's task, nil when
    /// nothing went remote.
    @discardableResult
    func newSessionFromButton(workspaceID: UUID, in store: AppStore) -> Task<Void, Never>? {
        let windowID = library.windowID(for: store)
        guard uiActionsEnabled(for: windowID) else { return nil }
        guard let host = settingsModel?.settings.effectiveNewSessionHost else {
            newLocalSession(workspaceID: workspaceID, in: store)
            return nil
        }
        guard let windowID, let createRemoteSession else {
            logger.notice("remote new session on \(host, privacy: .public) has no window or no control server; ignored")
            return nil
        }
        guard RemoteCreatePending.shared.begin(windowID) else { return nil }
        return Task { @MainActor in
            defer { RemoteCreatePending.shared.end(windowID) }
            switch await createRemoteSession(host, workspaceID, store) {
            case .attached:
                break
            case .refused(let error):
                reportRemoteCreateFailure("Could not create a session on \(host)", error, windowID)
            case .createdNotAttached(let remoteID, let error):
                reportRemoteCreateFailure("A session was created on \(host) but could not be attached",
                                          "\(error)\n\nIt is still on \(host) as \(remoteID).", windowID)
            }
        }
    }

    func newLocalSession(workspaceID: UUID, in store: AppStore) {
        guard uiActionsEnabled(for: library.windowID(for: store)),
              let session = store.addSession(toWorkspace: workspaceID, cwd: resolvedNewSessionCwd(),
                                             at: resolvedNewSessionIndex(in: workspaceID, store: store))
        else { return }
        // a user-initiated selection on THIS window's store: note activity so it buys the full idle grace
        // before auto-follow pulls away.
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    private func reportRemoteCreateFailure(_ title: String, _ message: String, _ windowID: UUID) {
        if let presentRemoteCreateFailure { return presentRemoteCreateFailure(title, message, windowID) }
        // a window closed during the round trip has nowhere to show the sheet
        guard let window = WindowRegistry.shared.window(for: windowID), window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}
