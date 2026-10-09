// The `rebased.mirror` family's dispatch (fork only).
extension ControlDispatcher {
    func dispatchRebasedMirrorCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .rebasedMirrorList:
            return await actions.listRebasedMirrors()
        case .rebasedMirrorPrune:
            let days = request.args?.olderThanDays
            // 0 would reopen the gap between a fetch's end and the host recording its mirror as opened
            if let days, days < 1 {
                return ControlResponse(ok: false, error: "rebased.mirror.prune --older-than must be 1 or more")
            }
            return await actions.pruneRebasedMirrors(olderThanDays: days, dryRun: request.args?.dryRun ?? false)
        default:
            preconditionFailure("unexpected rebased mirror command: \(request.cmd.rawValue)")
        }
    }
}
