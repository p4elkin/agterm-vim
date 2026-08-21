import Foundation

/// The bookmarks agterm holds, keyed for lookup by session and turn.
///
/// A value type on purpose: the app owns one and persists it (see `BookmarkPersistence`), so the store itself
/// touches no disk and no global state and stays testable without either.
public struct BookmarkStore: Codable, Equatable, Sendable {
    public private(set) var bookmarks: [Bookmark]

    public init(bookmarks: [Bookmark] = []) {
        self.bookmarks = bookmarks
    }

    /// Adds `bookmark`, or updates the one already held for the same session, run and turn.
    ///
    /// Bookmarking a turn twice is a correction, not a second bookmark, so the existing entry keeps its id and
    /// its place in the list and takes the new text and stamp. The returned value is what the store now holds,
    /// which on an update is NOT the argument: its id is the original's.
    ///
    /// ⚠️ `run` is part of the key. Turn numbers restart with the app while a restored session keeps its id, so
    /// matching on session and turn alone lets today's turn 3 overwrite yesterday's — destroying the prompt
    /// text, which after a restart is the only thing left of that turn.
    @discardableResult
    public mutating func add(_ bookmark: Bookmark) -> Bookmark {
        guard let index = bookmarks.firstIndex(where: {
            $0.sessionID == bookmark.sessionID && $0.turn == bookmark.turn && $0.run == bookmark.run
        }) else {
            bookmarks.append(bookmark)
            return bookmark
        }
        bookmarks[index].prompt = bookmark.prompt
        bookmarks[index].createdAt = bookmark.createdAt
        return bookmarks[index]
    }

    /// Every bookmark in insertion order, or only one session's when `sessionID` is given.
    public func list(sessionID: UUID? = nil) -> [Bookmark] {
        guard let sessionID else { return bookmarks }
        return bookmarks.filter { $0.sessionID == sessionID }
    }

    public func bookmark(sessionID: UUID, turn: Int) -> Bookmark? {
        bookmarks.first { $0.sessionID == sessionID && $0.turn == turn }
    }

    public func count(sessionID: UUID) -> Int {
        bookmarks.count { $0.sessionID == sessionID }
    }

    /// Removes one bookmark, answering whether it was there.
    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        bookmarks.remove(at: index)
        return true
    }

    /// A closed session takes its bookmarks with it — they are ditched, never orphaned.
    public mutating func dropSession(_ sessionID: UUID) {
        bookmarks.removeAll { $0.sessionID == sessionID }
    }
}
