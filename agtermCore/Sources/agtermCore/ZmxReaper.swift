import Foundation

/// Which detached zmx daemons a launch may end. Pure, because this is the second rule in the wrapping that
/// can destroy a live agent: everything here answers "is it certain nothing owns this session any more", and
/// every uncertain answer is no.
///
/// The claim comes from what is PERSISTED, never from what has restored. Window restoration is asynchronous
/// and a restored pane is zero-client until its client attaches, so a reap driven by live windows would kill
/// the agents of every window that had not come back yet.
public enum ZmxReaper {
    /// The keys the saved sessions claim by their own identity: both panes of every session in every window's
    /// snapshot. Half of the claim — `persistedClaim` adds the keys those files merely MENTION.
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

    /// Every owned key NAMED anywhere in a snapshot's stored text, whatever field it sits in.
    ///
    /// ⚠️ A row can be bound to a key that is not derived from its own id at all: `agterm-zmx pick` creates a
    /// row whose command is `zmx attach <another row's key>`, which this build leaves unwrapped and which
    /// therefore records no key of its own. Deriving the claim from session ids alone leaves that daemon
    /// unclaimed, zero-client at launch, and reaped — destroying the detached agent the pick existed to keep.
    /// Scanning the raw text rather than named fields is deliberate: a field added later is covered without
    /// anyone remembering to list it here, and an over-claim only ever spares a daemon.
    public static func keysMentioned(in text: String) -> Set<String> {
        var found: Set<String> = []
        for role in ZmxSessionKey.ownedRoleNames {
            let suffix = "-\(role)"
            var start = text.startIndex
            while let match = text.range(of: suffix, range: start..<text.endIndex) {
                start = match.upperBound
                guard let keyStart = text.index(match.lowerBound, offsetBy: -ZmxSessionKey.uuidLength,
                                                limitedBy: text.startIndex) else { continue }
                let candidate = String(text[keyStart..<match.upperBound])
                if ZmxSessionKey.isOwned(candidate) { found.insert(candidate) }
            }
        }
        return found
    }

    /// Everything the saved library claims, read straight off disk rather than through `WindowLibrary`,
    /// because the reap runs before any window has restored and must not wait for one: both role keys of
    /// every persisted session, plus every owned key those files mention in any other form.
    ///
    /// nil means the claim is UNKNOWN and the caller must skip the reap entirely: a missing `windows/`
    /// directory (a state directory this build has never written, or one still holding only the legacy
    /// `workspaces.json`), an unreadable directory, or any file that does not decode as a current snapshot.
    public static func persistedClaim(directory: URL) -> Set<String>? {
        let windows = directory.appendingPathComponent("windows", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: windows.path) else { return nil }
        var claimed: Set<String> = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: windows.appendingPathComponent(name)),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == Snapshot.currentVersion
            else { return nil }
            claimed.formUnion(claimedKeys(from: [snapshot]))
            claimed.formUnion(keysMentioned(in: String(decoding: data, as: UTF8.self)))
        }
        return claimed
    }
}
