import Foundation
import agtermCore

/// The Mac half of `control.forward`: a request a headless origin cannot serve, run on the one row presenting
/// the origin's session. The origin is not trusted to have applied `ForwardPolicy`, so it is applied again here.
extension ControlServer {
    /// `id` is the row whose presentation stream carried the request.
    func runForwarded(_ request: ControlRequest, forSession id: UUID) async -> ControlResponse {
        guard ForwardPolicy.route(request, holdsJob: false) == .forwarded else {
            return Self.forwardRefusal(request, "this Mac does not run it for an origin")
        }
        // a forwarded program would run on this Mac with text from the origin
        guard request.args?.command == nil else { return Self.forwardRefusal(request, "it carries a command") }
        guard let store = library.store(forSession: id),
              let remoteID = store.session(withID: id)?.remotePresentation?.binding.remoteSessionID,
              let windowID = library.windowID(for: store) else {
            return Self.forwardRefusal(request, "the row is no longer attached")
        }
        if request.cmd == .zmxAttach {
            guard let target = request.target, Self.sameSession(target, remoteID) else {
                return Self.forwardRefusal(request, "the target is not the session this row presents")
            }
            return await attachBeside(rowID: id, session: request.args?.attach ?? "")
        }
        var local = request
        // a pick or page poll names its own id, which this Mac issued
        let poll = request.cmd == .pickResult || request.cmd == .pickCancel
            || (request.cmd == .sessionOverlayResult && request.args?.page != nil)
        if !poll {
            guard let target = request.target, Self.sameSession(target, remoteID) else {
                return Self.forwardRefusal(request, "the target is not the session this row presents")
            }
            local.target = id.uuidString
            var args = request.args ?? ControlArgs()
            args.window = windowID.uuidString
            if request.cmd == .sessionOverlayOpen { args.resolved = true }
            local.args = args
        }
        var response = await dispatch(local)
        if response.result?.id == id.uuidString { response.result?.id = remoteID }
        return response
    }

    private static func sameSession(_ target: String, _ remoteID: String) -> Bool {
        guard let target = UUID(uuidString: target), let remote = UUID(uuidString: remoteID) else { return false }
        return target == remote
    }

    private static func forwardRefusal(_ request: ControlRequest, _ reason: String) -> ControlResponse {
        ControlResponse(ok: false, error: "forwarded \(request.cmd.rawValue) refused: \(reason)")
    }
}
