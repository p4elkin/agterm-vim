import agtermCore
import Foundation

/// Turns a wrapped pane's `zmx attach <key>` argv into the zmx session leader whose terminal the `tree` read
/// should look at instead. The decision is host-free (`ZmxForegroundSelection`); this owns the `zmx list`
/// call and the one listing it caches.
///
/// ONE instance per tree build: `tree --json` asks about every pane in the window, and `zmx list` is a
/// subprocess. The listing is fetched at most once per instance, lazily, so a window with no wrapped pane
/// spawns nothing at all.
@MainActor
final class ZmxForegroundResolver {
    private let client: ZmxClient
    /// Outer nil means "not asked yet"; `.some(nil)` records a fetch that failed, so one unreadable listing
    /// is not re-spawned for every remaining pane in the same tree build.
    private var listing: [ZmxListParser.Entry]??

    init(client: ZmxClient = .mainActorBounded) { self.client = client }

    /// The zmx session leader behind this pane's argv, or nil to report the argv as it is.
    func leaderPID(behind argv: [String]) -> pid_t? {
        // the argv shape is checked BEFORE the listing is touched: an ordinary pane must never pay for a
        // subprocess to learn it is ordinary.
        guard ZmxForegroundSelection.wrappedKey(argv: argv) != nil else { return nil }
        switch ZmxForegroundSelection.decide(argv: argv, listing: cachedListing()) {
        case .keepArgv: return nil
        case .inspect(let leaderPID, _): return pid_t(leaderPID)
        }
    }

    private func cachedListing() -> [ZmxListParser.Entry]? {
        if let listing { return listing }
        let fetched = client.list()
        listing = .some(fetched)
        return fetched
    }
}
