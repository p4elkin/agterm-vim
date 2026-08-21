import Foundation

/// A marked turn in an agent conversation: which session, which turn, and what was asked.
///
/// `prompt` is captured when the bookmark is made, not read back later. Scrollback does not outlive a
/// restart, so the mark this bookmark points at is often gone by the time it is used, and the stored text is
/// then the only thing left of the turn.
public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    /// Identifies THIS launch. The turn counter is ephemeral while a restored session keeps its persisted id
    /// (`AppStore+Snapshot`), so without it turn 3 of today collides with turn 3 of yesterday and the older
    /// bookmark's prompt is silently replaced — the one thing that survives a restart, since the mark itself
    /// does not.
    public static let currentRun = UUID()

    public let id: UUID
    public let sessionID: UUID
    public let turn: Int
    /// Absent on bookmarks written before runs were recorded; those never match a new add, so they are kept
    /// as history rather than overwritten.
    public let run: UUID?
    public var prompt: String
    public var createdAt: Date

    public init(id: UUID = UUID(), sessionID: UUID, turn: Int, run: UUID? = nil,
                prompt: String, createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.turn = turn
        self.run = run
        self.prompt = prompt
        self.createdAt = createdAt
    }

    /// The scrollback token `session.bookmark go` searches the pane for.
    public var needle: String { TurnMark.needle(for: turn) }
}
