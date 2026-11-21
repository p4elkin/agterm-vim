/// PresentationClearReason is what a presenter saw that may end its origin's status glyph or unseen badge. The origin
/// decides, so the reason travels rather than the outcome; a keystroke's clear also carries the presenter's own Status
/// reset, which the origin applies in place of its own.
public enum PresentationClearReason: String, Sendable {
    case key, submit, interrupt
    /// select: the presenter moved selection onto or off the session, which ends an auto-reset status.
    case select
    /// manual: the user cleared the status by hand.
    case manual
    /// viewed: the presenter showed the session to its user.
    case viewed

    public init(_ keystroke: StatusKeystroke) {
        switch keystroke {
        case .other: self = .key
        case .submit: self = .submit
        case .interrupt: self = .interrupt
        }
    }

    /// keystroke is the typing the reason stands for, nil for one that is not typing.
    public var keystroke: StatusKeystroke? {
        switch self {
        case .key: return .other
        case .submit: return .submit
        case .interrupt: return .interrupt
        case .select, .manual, .viewed: return nil
        }
    }
}

/// PresentationStatusClear asks the origin to end a session's status for `reason`; `pane` is the origin pane a
/// keystroke landed in, and `reset` the presenter's Status reset, nil from a presenter that sends none. All decode
/// leniently, nil when unknown, because a frame that fails to decode closes the
/// stream; the origin ignores a clear it cannot place.
public struct PresentationStatusClear: Codable, Equatable, Sendable {
    public var reason: PresentationClearReason?
    public var pane: PresentationPane?
    public var reset: StatusReset?

    private enum CodingKeys: String, CodingKey { case reason, pane, reset }

    public init(reason: PresentationClearReason, pane: PresentationPane? = nil, reset: StatusReset? = nil) {
        self.reason = reason
        self.pane = pane
        self.reset = reset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = (try? container.decode(String.self, forKey: .reason)).flatMap(PresentationClearReason.init(rawValue:))
        pane = try? container.decodeIfPresent(PresentationPane.self, forKey: .pane)
        reset = (try? container.decode(String.self, forKey: .reset)).flatMap(StatusReset.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reason?.rawValue, forKey: .reason)
        try container.encodeIfPresent(pane, forKey: .pane)
        try container.encodeIfPresent(reset?.rawValue, forKey: .reset)
    }
}

/// PresentationSeen asks the origin to lower a session's unseen badge for `reason`, nil when unknown.
public struct PresentationSeen: Codable, Equatable, Sendable {
    public var reason: PresentationClearReason?

    private enum CodingKeys: String, CodingKey { case reason }

    public init(reason: PresentationClearReason) { self.reason = reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = (try? container.decode(String.self, forKey: .reason)).flatMap(PresentationClearReason.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reason?.rawValue, forKey: .reason)
    }
}
