import Foundation

/// The app-global live `BookmarkStore` plus its persistence: the one mutable owner every command arm and the
/// session-close drop go through, so two windows cannot each hold a copy and clobber the other's writes.
///
/// `WindowLibrary` builds one at its own state directory; a nil persistence keeps it in-memory (tests, or a
/// host that wants no disk). Writes happen only on an actual change, so a library that never bookmarks
/// anything never creates the file.
@MainActor
public final class BookmarkCenter {
    private let persistence: BookmarkPersistence?
    public private(set) var store: BookmarkStore

    public init(persistence: BookmarkPersistence? = nil) {
        self.persistence = persistence
        store = persistence?.load() ?? BookmarkStore()
    }

    /// Adds or updates (same session + turn) and persists; returns what the store now holds — on an update
    /// that keeps the original's id, see `BookmarkStore.add`.
    @discardableResult
    public func add(sessionID: UUID, turn: Int, prompt: String) -> Bookmark {
        // stamped with THIS launch, so a restored session's repeated turn numbers cannot overwrite the
        // bookmarks made before the restart. See `Bookmark.currentRun`.
        let stored = store.add(Bookmark(sessionID: sessionID, turn: turn,
                                        run: Bookmark.currentRun, prompt: prompt))
        persist()
        return stored
    }

    public func list(sessionID: UUID? = nil) -> [Bookmark] {
        store.list(sessionID: sessionID)
    }

    public func count(sessionID: UUID) -> Int {
        store.count(sessionID: sessionID)
    }

    /// Removes the bookmark for `sessionID`+`turn`, answering whether it was there; persists only on a hit.
    @discardableResult
    public func remove(sessionID: UUID, turn: Int) -> Bool {
        guard let bookmark = store.bookmark(sessionID: sessionID, turn: turn) else { return false }
        _ = store.remove(id: bookmark.id)
        persist()
        return true
    }

    /// A closed session takes its bookmarks with it. No-op (and no disk write) when it had none.
    public func dropSession(_ sessionID: UUID) {
        guard store.count(sessionID: sessionID) > 0 else { return }
        store.dropSession(sessionID)
        persist()
    }

    /// Best-effort like `AppStore.save()`: a failed write keeps the in-memory truth and the next change retries.
    private func persist() {
        guard let persistence else { return }
        try? persistence.save(store)
    }
}
