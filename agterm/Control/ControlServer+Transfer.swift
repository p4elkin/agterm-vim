import Foundation
import agtermCore

/// `workspace.move --to-window` and `session.move --to-window`. Source targets resolve as the in-window moves
/// do; the move itself is `WindowLibrary+Transfer`, and this side only shows the destination window.
extension ControlServer {
    func transferWorkspace(_ target: String?, window: String?, toWindow: String, windowName: String?) async -> ControlResponse {
        var outcome: Result<TransferResult, TransferRefusal>?
        let resolved = resolver.resolveWorkspace(target, window: window) { store, workspaceID in
            outcome = transfer(from: store, toWindow: toWindow) { source, destination in
                library.transferWorkspace(workspaceID, from: source, to: destination, windowName: trimmed(windowName))
            }
            return ControlResponse(ok: true)
        }
        guard let outcome else { return resolved }
        return await present(outcome)
    }

    func transferSessions(_ targets: [String], window: String?, transfer request: ControlSessionTransfer) async -> ControlResponse {
        let workspace: TransferWorkspaceTarget
        switch (trimmed(request.workspace), request.workspaceName) {
        case (.some, .some): preconditionFailure("the dispatcher refuses a workspace with --workspace-name")
        case (.some(let id), nil): workspace = .id(id)
        case (nil, .some(let name)): workspace = .name(name)
        case (nil, nil): workspace = .none
        }
        var outcome: Result<TransferResult, TransferRefusal>?
        let resolved = resolveBatchSessions(targets, window: window) { store, ids in
            outcome = transfer(from: store, toWindow: request.toWindow) { source, destination in
                library.transferSessions(ids, from: source, to: destination, workspace: workspace,
                                         windowName: trimmed(request.windowName))
            }
            return ControlResponse(ok: true)
        }
        guard let outcome else { return resolved }
        return await present(outcome)
    }

    private func transfer(from store: AppStore, toWindow raw: String,
                          _ move: (UUID, TransferDestination) -> Result<TransferResult, TransferRefusal>)
        -> Result<TransferResult, TransferRefusal> {
        guard let source = library.windowID(for: store) else { return .failure(TransferRefusal("no open window")) }
        let outcome = library.resolveTransferDestination(raw, source: source).flatMap { move(source, $0) }
        if case .success(let result) = outcome {
            renewRemoteAttachments(result)
            // after the renewal, which skips an asleep row: a row woken first would get a second nonce its line lacks
            wakeShownMovedRows(result)
            // the debounced write would leave a crash in its gap restoring the row in the source window
            remoteRowBook?.write()
            // the library already deleted the emptied source; its willClose handler sees an empty store
            if let removed = result.removedSourceWindow { WindowRegistry.shared.close(removed) }
        }
        return outcome
    }

    /// Before the destination mounts: a remote pane's first line carries its last attachment's nonce, whose
    /// reports the lead book drops, and a user attach's claim. A fresh one, as `PaneReattach` builds.
    private func renewRemoteAttachments(_ result: TransferResult) {
        guard let store = library.store(for: result.windowID) else { return }
        // an asleep row moves asleep: its wake builds the lines
        result.sessionIDs.compactMap(store.session(withID:)).filter { !$0.asleep }.forEach(renewAttachLines(for:))
    }

    /// wakeShownMovedRows wakes the moved rows the destination shows, now that it owns them and the source released them.
    private func wakeShownMovedRows(_ result: TransferResult) {
        guard let store = library.store(for: result.windowID) else { return }
        store.wakeShown(onScreenRows(inWindow: result.windowID, store: store).intersection(result.sessionIDs), now: hudClock())
    }

    /// wakeAttachLines renews a woken row's pane lines and attaches the scratch its origin showed while it slept.
    func wakeAttachLines(for session: Session) {
        renewAttachLines(for: session)
        library.store(forSession: session.id)?.attachOriginScratch(forSession: session.id, attach: self)
    }

    /// renewAttachLines gives a remote terminal row fresh pane lines; one it cannot build is the ended line, never nil.
    func renewAttachLines(for session: Session) {
        guard let host = session.remoteHost, session.content == .terminal else { return }
        let binding = session.remotePresentation?.binding
        let ended = RemoteSession.endedCommand(host: binding?.origin?.host ?? host)
        // a row whose origin session ended while it slept has nothing to attach: a fresh line would only fail
        guard !session.ended, session.remotePresentation?.rowState != .endedOnHost else {
            session.initialCommand = ended
            if session.hasSplit, session.splitPaneIdentity != nil { session.splitInitialCommand = ended }
            return
        }
        let pool = sshPool(forSession: session.id)
        let left = ZmxLeadAttachment(claim: false, reclaim: ZmxLeadBook.shared.pendingReclaim(pane: session.paneIdentity))
        if let command = binding?.attachPaneCommand(forLocalPane: session.paneIdentity, pane: .left, lead: left,
                                                    controlPath: pool?.lease("pane:\(session.paneIdentity)")) {
            session.initialCommand = command
            ZmxLeadBook.shared.begin(left, pane: session.paneIdentity)
        } else {
            session.initialCommand = ended
        }
        guard session.hasSplit, let split = session.splitPaneIdentity else { return }
        let right = ZmxLeadAttachment(claim: false, reclaim: ZmxLeadBook.shared.pendingReclaim(pane: split))
        if let command = binding?.attachPaneCommand(forLocalPane: split, pane: .right, lead: right,
                                                    controlPath: pool?.lease("pane:\(split)")) {
            session.splitInitialCommand = command
            ZmxLeadBook.shared.begin(right, pane: split)
        } else {
            session.splitInitialCommand = ended
        }
    }

    /// Opens a new or loaded destination, raises an open one. The poll gates on the registry for the reason
    /// `windowNew` gives: the store is loaded before the NSWindow attaches.
    private func present(_ outcome: Result<TransferResult, TransferRefusal>) async -> ControlResponse {
        switch outcome {
        case .failure(let refusal):
            return ControlResponse(ok: false, error: refusal.message)
        case .success(let result):
            actions.openWindow?(result.windowID)
            await pollUntil { WindowRegistry.shared.isRegistered(result.windowID) }
            takeFrontmost(result.windowID)
            // the closed source took key focus with it; nothing else gives it to the destination's terminal
            if result.removedSourceWindow != nil { actions.focusActiveSession() }
            return ControlResponse(ok: true, result: result.controlResult)
        }
    }
}
