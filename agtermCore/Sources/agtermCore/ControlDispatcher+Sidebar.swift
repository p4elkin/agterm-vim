import Foundation

/// The sidebar view commands' mode parsing, split out for the same reason `+Parked` and `+Hud` are.
extension ControlDispatcher {
    /// `sidebar show|hide|toggle`.
    func dispatchSidebar(_ request: ControlRequest) -> ControlResponse {
        guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
            return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
        }
        return actions.setSidebarVisibility(mode)
    }

    /// `sidebar.mode tree|flagged|toggle`.
    func dispatchSidebarMode(_ request: ControlRequest) -> ControlResponse {
        guard let mode = ControlSidebarViewMode.parse(request.args?.mode) else {
            return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
        }
        return actions.setSidebarViewMode(mode)
    }

    /// `sidebar.flagged-layout flat|tree|toggle`.
    func dispatchSidebarFlaggedLayout(_ request: ControlRequest) -> ControlResponse {
        guard let mode = ControlFlaggedLayoutMode.parse(request.args?.mode) else {
            return ControlResponse(ok: false, error: "invalid flagged layout: \(request.args?.mode ?? "toggle")")
        }
        return actions.setFlaggedViewLayout(mode)
    }
}
