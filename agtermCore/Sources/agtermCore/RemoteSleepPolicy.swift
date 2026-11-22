import Foundation

/// RemoteSleepReason is why a remote row slept (`timer`, `command`, `launch`) or woke (`shown`, `command`, `pty`),
/// carried as the `session.slept` / `session.woke` payload's `reason`.
public enum RemoteSleepReason: String, Codable, Sendable, Equatable {
    case timer, command, launch
    case shown, pty
}

/// RemoteSleepPolicy picks the remote rows that have been off screen long enough to sleep.
public enum RemoteSleepPolicy {
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        public let eligible: Bool
        public let asleep: Bool
        public let offScreenSince: Date?

        public init(id: UUID, eligible: Bool, asleep: Bool, offScreenSince: Date?) {
            self.id = id
            self.eligible = eligible
            self.asleep = asleep
            self.offScreenSince = offScreenSince
        }
    }

    /// The candidates off screen for at least `minutes`; 0 means never.
    public static func rowsToSleep(rows: [Candidate], now: Date, after minutes: Int) -> [UUID] {
        guard minutes > 0 else { return [] }
        let limit = TimeInterval(minutes) * 60
        return rows.filter { row in
            guard row.eligible, !row.asleep, let since = row.offScreenSince else { return false }
            return now.timeIntervalSince(since) >= limit
        }.map(\.id)
    }
}
