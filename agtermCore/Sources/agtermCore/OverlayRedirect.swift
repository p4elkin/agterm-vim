import Foundation

/// The workstation session a mirrored row stands in for. Set by `agterm-zmx-mirror` on the LAPTOP's row when
/// it creates it, and read back to send an overlay's program to the machine that holds the files.
public struct OverlayMirrorSource: Codable, Equatable, Sendable {
    /// The host running the real session.
    public var host: String
    /// The session key on `host`.
    public var session: String
    /// The remote session's own working directory, re-asserted by the mirror job on every pass.
    ///
    /// ⚠️ Optional, and it has to stay that way: a pairing written by an older mirror job carries none, and a
    /// throw in `SessionSnapshot`'s lossy decode costs the whole session tree rather than one field.
    ///
    /// Carried because the mirrored row cannot answer the question itself. Its `currentCwd` is never set —
    /// the remote shell's OSC 7 names the workstation's host and libghostty drops it as not local — so the row
    /// falls back to the `initialCwd` the mirror job pinned, `$HOME`. That path exists on BOTH machines, so a
    /// redirected `cd` succeeded and the overlay opened in the wrong directory with nothing to show for it.
    public var cwd: String?

    public init(host: String, session: String, cwd: String? = nil) {
        self.host = host
        self.session = session
        self.cwd = cwd
    }
}

/// A remote agterm watching this session. Set on the WORKSTATION by the laptop's mirror job over the ssh
/// connection it already opens, and refreshed on every pass. Discovery is by registration because the
/// workstation cannot see the laptop's rows without a network call, and a sleeping laptop costs a full
/// TCP timeout.
public struct OverlayViewer: Codable, Equatable, Sendable {
    /// The host sitting in front of the mirrored row.
    public var host: String
    /// The mirrored row's session key on `host` — where a redirected overlay opens.
    public var row: String
    /// Epoch seconds of the last refresh. Epoch rather than `Date` because the mirror job writes it from the
    /// shell, and because a laptop that closes its lid cannot clear the field itself: age is the only proof.
    public var confirmedAt: Double

    public init(host: String, row: String, confirmedAt: Double) {
        self.host = host
        self.row = row
        self.confirmedAt = confirmedAt
    }
}

/// Where the next overlay for a session opens, and what its program is wrapped in.
public enum OverlayRedirectOutcome: Equatable, Sendable {
    /// Open here, run here. The desk path, with no ssh anywhere near it.
    case local
    /// This row mirrors a session on `host`: open here, wrap the program in ssh to `host`, and `cd` there
    /// first when the pairing recorded a directory. Nil `cwd` leaves the choice to the caller, which is the
    /// behaviour a pairing from an older mirror job gets.
    case mirrorOf(host: String, cwd: String?)
    /// A row on `host` is watching this session: send the open there, wrap the program in ssh back to here.
    case watchedBy(host: String, row: String)

    /// The title-bar pill, derived here so pill and behaviour can never disagree. Green on the machine the
    /// overlay lands on, red on the one giving its overlays away, grey when the next overlay stays put.
    public var pill: OverlayRedirectPill {
        switch self {
        case .local: return .grey
        case .mirrorOf: return .green
        case .watchedBy: return .red
        }
    }
}

/// The pill's three states, host-free so the colour rule lives beside the decision rather than in the view.
public enum OverlayRedirectPill: Equatable, Sendable {
    case grey, green, red
}

/// Phase one's answer to `session.overlay.open`: the app opened NOTHING and is telling `agtermctl` where the
/// overlay belongs. `agtermctl` wraps the program in ssh accordingly and re-sends with `resolved` set, which
/// skips the decision. `.local` has no wire form — it opens as today and answers as today.
public struct ControlOverlayRedirect: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case mirrorOf = "mirror-of"
        case watchedBy = "watched-by"
    }

    public var outcome: Outcome
    /// Where the far side is: the host to run the program on for `mirrorOf`, the host to open the overlay on
    /// for `watchedBy`.
    public var host: String
    /// The viewer's mirrored row on `host`, `watchedBy` only — the session the overlay opens on over there.
    public var row: String?
    /// The directory to `cd` into on `host` before the program runs, `mirrorOf` only. Nil when the pairing
    /// recorded none, which leaves `agtermctl` on its own process directory as before.
    public var cwd: String?

    public init(outcome: Outcome, host: String, row: String? = nil, cwd: String? = nil) {
        self.outcome = outcome
        self.host = host
        self.row = row
        self.cwd = cwd
    }
}

extension OverlayRedirectOutcome {
    /// The wire answer, nil for `.local`. One mapping, so the control server never restates the rule.
    public var redirect: ControlOverlayRedirect? {
        switch self {
        case .local:
            return nil
        case .mirrorOf(let host, let cwd):
            return ControlOverlayRedirect(outcome: .mirrorOf, host: host, cwd: cwd)
        case .watchedBy(let host, let row):
            return ControlOverlayRedirect(outcome: .watchedBy, host: host, row: row)
        }
    }
}

/// The redirect decision: toggle plus pairing in, one outcome out.
public enum OverlayRedirect {
    /// Twice the mirror job's 20-second pass, so one missed pass is not treated as a gone viewer.
    public static let stalenessWindow: Double = 40

    /// - Parameter now: epoch seconds, passed in rather than read, so the staleness rule is testable.
    ///
    /// A row that mirrors something wins over a viewer on the same session: the overlay is then already on the
    /// machine being looked at, so sending it away would move it off that machine.
    public static func outcome(enabled: Bool,
                               mirrors: OverlayMirrorSource?,
                               viewer: OverlayViewer?,
                               now: Double,
                               staleness: Double = stalenessWindow) -> OverlayRedirectOutcome {
        guard enabled else { return .local }
        if let mirrors { return .mirrorOf(host: mirrors.host, cwd: mirrors.cwd) }
        guard let viewer, now - viewer.confirmedAt <= staleness else { return .local }
        return .watchedBy(host: viewer.host, row: viewer.row)
    }
}
