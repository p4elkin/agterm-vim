/// AttentionCounts is what the collapsed-sidebar attention pill draws: one number per category, so a window
/// with no sidebar still says how much needs attention and of what kind. `blocked`/`active`/`completed` count
/// sessions across every workspace in the window; `unseen` is the active session's unread notifications alone,
/// a different kind of thing, which is why it is not derived from the same list.
public struct AttentionCounts: Equatable, Sendable {
    public let blocked: Int
    public let active: Int
    public let completed: Int
    public let unseen: Int

    public init(blocked: Int = 0, active: Int = 0, completed: Int = 0, unseen: Int = 0) {
        self.blocked = blocked
        self.active = active
        self.completed = completed
        self.unseen = unseen
    }

    /// Nothing to report, so the pill renders nothing at all rather than an empty capsule.
    public var isEmpty: Bool { blocked == 0 && active == 0 && completed == 0 && unseen == 0 }

    /// Takes the raw inputs rather than an AppStore so the rule is testable with no host. `.idle` counts into
    /// nothing — callers pass `attentionSessions`, which already drops idle, but a stray one must not create a
    /// bucket of its own.
    public static func make(statuses: [AgentStatus], activeUnseen: Int) -> AttentionCounts {
        AttentionCounts(
            blocked: statuses.count { $0 == .blocked },
            active: statuses.count { $0 == .active },
            completed: statuses.count { $0 == .completed },
            unseen: activeUnseen
        )
    }
}
