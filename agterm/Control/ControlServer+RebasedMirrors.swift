import agtermCore
import Foundation

/// The `rebased.mirror` family (fork only). The payload is mapped in `RebasedMirrorCleanup.swift`.
extension ControlServer {
    func listRebasedMirrors() async -> ControlResponse {
        let mirrors = await RebasedHost.shared.listMirrors()
        return ControlResponse(ok: true, result: ControlResult(rebasedMirrors: ControlRebasedMirrors(mirrors: mirrors)))
    }

    func pruneRebasedMirrors(olderThanDays: Int?, dryRun: Bool) async -> ControlResponse {
        let days = olderThanDays ?? settingsModel.settings.effectiveRebasedMirrorMaxAgeDays
        guard days > 0 else {
            return ControlResponse(ok: false,
                                   error: "automatic mirror pruning is off (rebasedMirrorMaxAgeDays is 0); pass --older-than DAYS")
        }
        do {
            let report = try await RebasedHost.shared.pruneMirrors(olderThanDays: days, dryRun: dryRun)
            return ControlResponse(ok: true, result: ControlResult(rebasedMirrors: ControlRebasedMirrors(report: report)))
        } catch {
            return ControlResponse(ok: false, error: error.localizedDescription)
        }
    }
}
