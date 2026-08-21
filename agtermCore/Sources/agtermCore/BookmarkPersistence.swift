import Foundation

/// Reads and writes the `BookmarkStore` as JSON in the same directory as the workspace snapshot, so the
/// `AGTERM_STATE_DIR` test override applies. Mirrors `PersistenceStore`: `load()` never throws to the
/// caller, `save(_:)` writes atomically (temp file then replace).
///
/// Its own file rather than a field on `Snapshot`: the snapshot resets to empty whenever its version does not
/// match (`Snapshot.currentVersion`), and a schema bump elsewhere in the app has no business discarding
/// bookmarks.
public struct BookmarkPersistence {
    private let directory: URL
    private let fileName = "bookmarks.json"

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// Creates a store rooted at `directory`, defaulting to the app's Application Support directory — the
    /// same root `PersistenceStore` uses.
    public init(directory: URL = PersistenceStore.defaultDirectory) {
        self.directory = directory
    }

    /// Loads the bookmarks, recovering an empty store on any failure (missing directory, missing file,
    /// unreadable data, corrupt JSON).
    public func load() -> BookmarkStore {
        guard let data = try? Data(contentsOf: fileURL) else { return BookmarkStore() }
        guard let store = try? JSONDecoder().decode(BookmarkStore.self, from: data) else { return BookmarkStore() }
        return store
    }

    /// Writes the bookmarks atomically, creating the directory if needed.
    public func save(_ store: BookmarkStore) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try data.write(to: fileURL, options: .atomic)
    }
}
