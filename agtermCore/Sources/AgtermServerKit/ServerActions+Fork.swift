import agtermCore

/// The fork's `ControlActions` requirements, which agterm-server does not serve; `ServerCommandPolicy` refuses their
/// commands before dispatch.
extension ServerActions {
    public func setSessionParked(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        forkOnly("setSessionParked")
    }
    public func markSessionTurn(_ target: String?, window: String?, paneID: String?) -> ControlResponse { forkOnly("markSessionTurn") }
    public func addSessionBookmark(_ target: String?, window: String?, turn: Int?, prompt: String) -> ControlResponse {
        forkOnly("addSessionBookmark")
    }
    public func listSessionBookmarks(_ target: String?, window: String?, all: Bool) -> ControlResponse {
        forkOnly("listSessionBookmarks")
    }
    public func removeSessionBookmark(_ target: String?, window: String?, turn: Int) -> ControlResponse {
        forkOnly("removeSessionBookmark")
    }
    public func setSidebarParked(window: String?, mode: ControlParkedVisibilityMode, scope: ControlParkedScope) -> ControlResponse {
        forkOnly("setSidebarParked")
    }

    public func setNormalMode(_ mode: ControlToggleMode) -> ControlResponse { forkOnly("setNormalMode") }
    public func setOverlayPairing(_ target: String?, window: String?, update: ControlOverlayPairingUpdate) -> ControlResponse {
        forkOnly("setOverlayPairing")
    }
    public func setOverlayRedirectToggle(_ mode: ControlToggleMode) -> ControlResponse { forkOnly("setOverlayRedirectToggle") }

    private func forkOnly(_ name: String) -> ControlResponse {
        ControlResponse(ok: false, error: "\(name) is not available on agterm-server")
    }
}
