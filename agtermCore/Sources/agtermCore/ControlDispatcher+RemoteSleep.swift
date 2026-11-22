import Foundation

extension ControlDispatcher {
    /// `session.sleep` / `session.wake`: the host decides eligibility and whether the row is on screen.
    func dispatchRemoteSleep(_ request: ControlRequest) -> ControlResponse {
        actions.setSessionAsleep(request.target, window: request.args?.window, asleep: request.cmd == .sessionSleep)
    }
}
