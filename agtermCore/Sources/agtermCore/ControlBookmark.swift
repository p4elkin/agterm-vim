import Foundation

/// One bookmark as `session.bookmark.list` reports it — the row the fzf hub renders and hands back.
/// `needle` is included so a script can `session.search` for the mark without spelling `TurnMark` inline,
/// which is the drift the type exists to prevent. Its own file because `ControlProtocol.swift` sits at the
/// file-length limit.
public struct ControlBookmarkNode: Codable, Sendable, Equatable {
    public let id: String
    /// The owning session's uuid — what `session.bookmark.go`/`.remove` take as `--target`.
    public let session: String
    /// The owning session's display name at list time (for the cross-session hub view); nil when the
    /// session is not in any open window.
    public let sessionName: String?
    public let turn: Int
    /// The prompt text captured at bookmark time — what the hub shows when the mark has left scrollback.
    public let prompt: String
    /// Creation time in seconds since the Unix epoch, so a script can sort without parsing dates.
    public let created: Double
    /// The scrollback token `session.bookmark.go` searches for (`TurnMark.needle`).
    public let needle: String

    public init(id: String, session: String, sessionName: String?, turn: Int, prompt: String,
                created: Double, needle: String) {
        self.id = id
        self.session = session
        self.sessionName = sessionName
        self.turn = turn
        self.prompt = prompt
        self.created = created
        self.needle = needle
    }

    /// The projection every arm uses, so the wire shape cannot drift between `list` and `list --all`.
    public init(_ bookmark: Bookmark, sessionName: String?) {
        self.init(id: bookmark.id.uuidString, session: bookmark.sessionID.uuidString,
                  sessionName: sessionName, turn: bookmark.turn, prompt: bookmark.prompt,
                  created: bookmark.createdAt.timeIntervalSince1970, needle: bookmark.needle)
    }
}
