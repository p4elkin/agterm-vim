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
        case (.some, .some): return ControlResponse(ok: false, error: "a workspace and --workspace-name are exclusive")
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
        return library.resolveTransferDestination(raw, source: source).flatMap { move(source, $0) }
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
            return ControlResponse(ok: true, result: result.controlResult)
        }
    }
}
