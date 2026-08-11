import Foundation

/// The zmx session name a wrapped pane owns: `<session uuid>-<pane role>`, an UPPERCASE uuid and a
/// lowercase role. That is byte for byte what the `~/.zprofile` hook builds from `AGTERM_SESSION_ID` and
/// `AGTERM_PANE`, so a daemon the hook already started is adopted rather than duplicated, and `zmx list`,
/// the pick list, the mosh incantation and `agterm-remote-overlay` all keep parsing the shape they expect.
public enum ZmxSessionKey {
    /// `key(sessionID:isSplit:)` produces only `left` and `right` — a scratch or overlay surface is never
    /// wrapped. `scratch` and `overlay` are still recognised so a daemon the outside tooling left under one
    /// of them stays reapable; this matches `agterm-zmx-sync`'s own role alternation.
    public enum Role: String, Sendable, CaseIterable {
        case left, right, scratch, overlay
    }

    /// A key split back into the parts the reaper and the lifecycle predicate need.
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
    /// only names this accepts, so a session someone created by hand must never read as a pane key.
    public static func isOwned(_ name: String) -> Bool { parse(name) != nil }

    /// Splits at the LAST hyphen, because a uuid contains hyphens of its own and no role does.
    public static func parse(_ name: String) -> Parsed? {
        guard let separator = name.lastIndex(of: "-"),
              let role = Role(rawValue: String(name[name.index(after: separator)...])),
              let sessionID = UUID(uuidString: String(name[..<separator]))
        else { return nil }
        return Parsed(sessionID: sessionID, role: role)
    }

    /// Worst-case key size for `ZmxSocketBudget`'s probe: a uuid string is always 36 bytes, and the longest
    /// role is taken over every case rather than the two a wrapped pane can be, so adding a role later
    /// cannot quietly shrink the socket-path margin.
    public static let maxByteCount = 36 + 1 + (Role.allCases.map { $0.rawValue.utf8.count }.max() ?? 0)
}
