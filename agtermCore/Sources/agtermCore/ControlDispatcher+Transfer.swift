import Foundation

extension ControlDispatcher {
    /// `workspace.move --to-window`. Split out of `ControlDispatcher.swift`, whose type body is near the
    /// length limit, following `+Zmx`.
    func dispatchWorkspaceTransfer(_ request: ControlRequest) async -> ControlResponse {
        guard let args = request.args, let toWindow = args.toWindow else {
            preconditionFailure("workspace transfer without toWindow")
        }
        guard args.to == nil else {
            return ControlResponse(ok: false, error: "--to and --to-window are exclusive")
        }
        return await actions.transferWorkspace(request.target, window: args.window, toWindow: toWindow,
                                               windowName: args.windowName)
    }

    /// `session.move --to-window`. A single `target` travels as a batch of one.
    func dispatchSessionTransfer(_ request: ControlRequest) async -> ControlResponse {
        guard let args = request.args, let toWindow = args.toWindow else {
            preconditionFailure("session transfer without toWindow")
        }
        guard args.to == nil, args.after == nil, args.before == nil else {
            return ControlResponse(ok: false, error: "--to-window cannot be combined with --to, --after or --before")
        }
        let targets = args.targets ?? [request.target ?? "active"]
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "session.move requires at least one --target")
        }
        let transfer = ControlSessionTransfer(toWindow: toWindow, workspace: args.workspace,
                                              workspaceName: args.workspaceName, windowName: args.windowName)
        return await actions.transferSessions(targets, window: args.window, transfer: transfer)
    }
}
