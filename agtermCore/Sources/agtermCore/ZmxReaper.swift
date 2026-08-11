import Foundation

/// Which detached zmx daemons a launch may end. Pure, because this is the second rule in the wrapping that
/// can destroy a live agent: everything here answers "is it certain nothing owns this session any more", and
/// every uncertain answer is no.
///
/// The claim comes from what is PERSISTED, never from what has restored. Window restoration is asynchronous
/// and a restored pane is zero-client until its client attaches, so a reap driven by live windows would kill
/// the agents of every window that had not come back yet.
public enum ZmxReaper {
    /// Every key the saved library still claims: both panes of every session in every window's snapshot.
    ///
    /// Deliberately over-broad. Claiming the right pane of a row that never split spares a daemon that does
    /// not exist, which costs nothing; missing one key kills a live agent.
    public static func claimedKeys(from snapshots: [Snapshot]) -> Set<String> {
        var keys: Set<String> = []
        for session in snapshots.flatMap(\.workspaces).flatMap(\.sessions) {
            keys.insert(ZmxSessionKey.key(sessionID: session.id, isSplit: false))
            keys.insert(ZmxSessionKey.key(sessionID: session.id, isSplit: true))
        }
        return keys
    }

    /// The listed sessions this launch may kill: an agterm-shaped name, a client count of EXACTLY zero, and
    /// no claim on it. An unknown count (`clients == nil`, a session zmx could not read) is never an orphan.
    public static func orphans(in listing: [ZmxListParser.Entry], claimed: Set<String>) -> [String] {
        listing.filter { $0.clients == 0 && ZmxSessionKey.isOwned($0.name) && !claimed.contains($0.name) }
            .map(\.name)
    }

    /// Every window's saved snapshot, read straight off disk rather than through `WindowLibrary`, because the
    /// reap runs before any window has restored and must not wait for one.
    ///
    /// nil means the claim is UNKNOWN and the caller must skip the reap entirely: a missing `windows/`
    /// directory (a state directory this build has never written, or one still holding only the legacy
    /// `workspaces.json`), an unreadable directory, or any file that does not decode as a current snapshot.
    public static func persistedSnapshots(directory: URL) -> [Snapshot]? {
        let windows = directory.appendingPathComponent("windows", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: windows.path) else { return nil }
        var snapshots: [Snapshot] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: windows.appendingPathComponent(name)),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == Snapshot.currentVersion
            else { return nil }
            snapshots.append(snapshot)
        }
        return snapshots
    }
}
