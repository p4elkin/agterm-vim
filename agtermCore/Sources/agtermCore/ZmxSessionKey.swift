import Foundation

/// The zmx session name a wrapped pane owns: `<session uuid>-<pane role>`, an UPPERCASE uuid and a
/// lowercase role. That is byte for byte what the `~/.zprofile` hook builds from `AGTERM_SESSION_ID` and
/// `AGTERM_PANE`, so a daemon the hook already started is adopted rather than duplicated, and `zmx list`,
/// the pick list, the mosh incantation and `agterm-remote-overlay` all keep parsing the shape they expect.
public enum ZmxSessionKey {
    /// The only two roles a key can carry. A scratch or overlay surface is not a persistent row and is never
    /// wrapped, so it has no case here at all — which is also what keeps the key short enough for the socket
    /// path budget, where `overlay` alone cost two of the four spare bytes.
    public enum Role: String, Sendable, CaseIterable {
        case left, right
    }

    /// Role names the OUTSIDE tooling may have left a daemon under (`agterm-zmx-sync` alternates over four).
    /// Recognized by `isOwned` so the reaper can end one, never produced by `key`.
    static let legacyRoleNames = ["scratch", "overlay"]

    /// A key split back into the parts the wrap decision needs.
    public struct Parsed: Equatable, Sendable {
        public let sessionID: UUID
        public let role: Role

        public init(sessionID: UUID, role: Role) {
            self.sessionID = sessionID
            self.role = role
        }
    }

    /// `sessionID.uuidString` is uppercase, and it is the same value the pane's own `AGTERM_SESSION_ID`
    /// carries (`SurfaceEnvironment.session`), so an app-built key and a hook-built key are identical.
    public static func key(sessionID: UUID, isSplit: Bool) -> String {
        "\(sessionID.uuidString)-\(isSplit ? Role.right.rawValue : Role.left.rawValue)"
    }

    /// Whether this zmx session name belongs to agterm. What it REJECTS is what matters: the reaper kills
    /// only names this accepts, so a session someone created by hand must never read as a pane key. Wider
    /// than `parse`, which answers only for a key this build could have produced.
    public static func isOwned(_ name: String) -> Bool {
        guard let (sessionID, role) = split(name) else { return false }
        return sessionID != nil && (Role(rawValue: role) != nil || legacyRoleNames.contains(role))
    }

    /// Splits at the LAST hyphen, because a uuid contains hyphens of its own and no role does.
    public static func parse(_ name: String) -> Parsed? {
        guard let (sessionID, role) = split(name), let sessionID, let role = Role(rawValue: role)
        else { return nil }
        return Parsed(sessionID: sessionID, role: role)
    }

    /// The uuid (nil when the prefix is not one) and the raw role suffix; nil for a name with no hyphen.
    ///
    /// ⚠️ The prefix must match `uuidString` byte for byte, not merely parse. `UUID(uuidString:)` is
    /// case-insensitive while `key` only ever emits uppercase, so a lowercase-uuid daemon would read as owned
    /// yet never appear in `ZmxReaper.claimedKeys` — an unclaimable name the reaper kills on sight.
    private static func split(_ name: String) -> (sessionID: UUID?, role: String)? {
        guard let separator = name.lastIndex(of: "-") else { return nil }
        let prefix = String(name[..<separator])
        let sessionID = UUID(uuidString: prefix).flatMap { $0.uuidString == prefix ? $0 : nil }
        return (sessionID, String(name[name.index(after: separator)...]))
    }

    /// Worst-case key size for `ZmxSocketBudget`'s probe: a uuid string is always 36 bytes plus a separator
    /// and the longest role. Taken over `Role.allCases` rather than written down, so adding a role fails the
    /// budget test instead of quietly eating the socket-path margin.
    public static let maxByteCount = 36 + 1 + (Role.allCases.map { $0.rawValue.utf8.count }.max() ?? 0)
}
