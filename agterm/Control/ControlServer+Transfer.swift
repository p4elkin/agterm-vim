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
        for session in result.sessionIDs.compactMap(store.session(withID:)) {
            guard let binding = session.remotePresentation?.binding else { continue }
            let left = ZmxLeadAttachment(claim: false)
            if let command = binding.attachPaneCommand(forLocalPane: session.paneIdentity, pane: .left, lead: left) {
                session.initialCommand = command
                ZmxLeadBook.shared.begin(left, pane: session.paneIdentity)
            }
            guard session.hasSplit, let split = session.splitPaneIdentity else { continue }
            let right = ZmxLeadAttachment(claim: false)
            if let command = binding.attachPaneCommand(forLocalPane: split, pane: .right, lead: right) {
                session.splitInitialCommand = command
                ZmxLeadBook.shared.begin(right, pane: split)
            }
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
