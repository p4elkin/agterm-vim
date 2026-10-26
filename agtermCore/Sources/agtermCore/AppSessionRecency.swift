import Foundation

/// The app-wide visit order (fork only): sessions most recently visited in any window, most recent first.
/// `WindowLibrary` owns one; a nil persistence keeps it in memory.
@MainActor
public final class AppSessionRecency {
    private let persistence: AppSessionRecencyPersistence?
    private var stack: RecencyStack<UUID>
    /// True until a usable file was loaded or a seed ran, so a seed fills only a list that never had one.
    public private(set) var isFresh: Bool

    public var items: [UUID] { stack.items }

    public init(persistence: AppSessionRecencyPersistence? = nil) {
        self.persistence = persistence
        let loaded = persistence?.load()
        stack = RecencyStack(limit: 100, items: loaded ?? [])
        isFresh = loaded == nil
    }

    public func push(_ id: UUID) {
        mutate { $0.push(id) }
    }

    public func forget(_ ids: some Sequence<UUID>) {
        mutate { stack in ids.forEach { stack.remove($0) } }
    }

    /// Appends `ids` behind anything already pushed, once, and only on a fresh list.
    public func seed(_ ids: [UUID]) {
        guard isFresh else { return }
        isFresh = false
        mutate { $0 = RecencyStack(limit: $0.limit, items: $0.items + ids) }
    }

    private func mutate(_ change: (inout RecencyStack<UUID>) -> Void) {
        let before = stack
        change(&stack)
        guard stack != before, let persistence else { return }
        // best-effort like `BookmarkCenter`: a failed write keeps the in-memory list and the next change retries
        try? persistence.save(stack.items)
    }
}

/// Reads and writes the visit order as `session-recency.json` in the state directory. Its own file, not a
/// `windows.json` field: one bad value there fails the whole index decode.
public struct AppSessionRecencyPersistence {
    private struct File: Codable {
        var sessions: [UUID]
    }

    private let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("session-recency.json") }

    public init(directory: URL = PersistenceStore.defaultDirectory) {
        self.directory = directory
    }

    /// Nil for a missing, unreadable or corrupt file.
    public func load() -> [UUID]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONDecoder().decode(File.self, from: data))?.sessions
    }

    public func save(_ sessions: [UUID]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(File(sessions: sessions)).write(to: fileURL, options: .atomic)
    }
}

/// One `appSessionRecency` tree entry: a visited session and the open window holding it.
public struct ControlRecentSession: Codable, Sendable, Equatable {
    public let session: String
    public let window: String

    public init(session: String, window: String) {
        self.session = session
        self.window = window
    }
}
