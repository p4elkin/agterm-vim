import Foundation

extension ControlDispatcher {
    func dispatchSessionRebased(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionRebasedShow:
            switch Self.parseRebasedView(request.args, command: request.cmd.rawValue, requiresRebasedFlag: false) {
            case .rejected(let response): return response
            case .view(let view):
                guard let view else {
                    return ControlResponse(ok: false, error: "session.rebased.show: provide exactly one of --diff and --file")
                }
                return actions.showRebasedView(request.target, window: request.args?.window, view: view)
            }
        case .sessionRebasedToggle:
            return actions.toggleRebasedOverlay(request.target, window: request.args?.window)
        default:
            preconditionFailure("unexpected Rebased command: \(request.cmd.rawValue)")
        }
    }
}
