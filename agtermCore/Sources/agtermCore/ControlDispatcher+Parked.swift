import Foundation

/// The two parked commands' argument parsing, split out for the same reason `+Hud` and `+Pick` are.
///
/// Both parse and REJECT before the host runs, so an unknown mode never half-applies.
extension ControlDispatcher {
    /// `session.park on|off|toggle`. `clear` lands here as an unknown mode, which is the point:
    /// `session.flag`'s clear-everything has no parked twin.
    func dispatchSessionParked(_ request: ControlRequest) -> ControlResponse {
        guard let mode = ControlToggleMode.parse(request.args?.mode) else {
            return ControlResponse(ok: false, error: "invalid park mode: \(request.args?.mode ?? "toggle")")
        }
        return actions.setSessionParked(request.target, window: request.args?.window, mode: mode)
    }

    /// `sidebar.parked show|hide|toggle [--workspace <id|active|all>]`. `all` is decided here because it is
    /// grammar, not a target; an id or `active` stays raw for the host to resolve.
    func dispatchSidebarParked(_ request: ControlRequest) -> ControlResponse {
        let raw = request.args?.mode ?? ControlParkedVisibilityMode.toggle.rawValue
        guard let mode = ControlParkedVisibilityMode(rawValue: raw) else {
            return ControlResponse(ok: false,
                           error: "invalid parked mode: \(raw) (\(ControlParkedVisibilityMode.validNamesList))")
        }
        let scope: ControlParkedScope
        switch request.args?.workspace {
        case nil: scope = .window
        case "all": scope = .all
        case .some(let target): scope = .workspace(target)
        }
        return actions.setSidebarParked(window: request.args?.window, mode: mode, scope: scope)
    }
}
