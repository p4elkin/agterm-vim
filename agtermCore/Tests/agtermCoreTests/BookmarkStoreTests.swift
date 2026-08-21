import Foundation
import Testing
@testable import agtermCore

struct BookmarkStoreTests {
    private let sessionA = UUID()
    private let sessionB = UUID()

    private func bookmark(_ session: UUID, _ turn: Int, _ prompt: String = "prompt",
                          createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Bookmark {
        Bookmark(sessionID: session, turn: turn, prompt: prompt, createdAt: createdAt)
    }

    @Test func addThenListRoundTrips() {
        var store = BookmarkStore()
        let added = store.add(bookmark(sessionA, 3, "explain the parser"))
        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed.first == added)
        #expect(listed.first?.sessionID == sessionA)
        #expect(listed.first?.turn == 3)
        #expect(listed.first?.prompt == "explain the parser")
    }

    @Test func listKeepsInsertionOrder() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))
        store.add(bookmark(sessionB, 9))
        store.add(bookmark(sessionA, 2))
        #expect(store.list().map(\.turn) == [1, 9, 2])
    }

    @Test func listForOneSessionSkipsTheOthers() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))
        store.add(bookmark(sessionB, 9))
        store.add(bookmark(sessionA, 2))
        #expect(store.list(sessionID: sessionA).map(\.turn) == [1, 2])
        #expect(store.list(sessionID: sessionB).map(\.turn) == [9])
    }

    @Test func addingTheSameTurnTwiceUpdatesInsteadOfDuplicating() {
        var store = BookmarkStore()
        let first = store.add(bookmark(sessionA, 4, "first wording"))
        let second = store.add(bookmark(sessionA, 4, "second wording"))
        #expect(store.list().count == 1)
        #expect(store.list().first?.prompt == "second wording")
        #expect(second.id == first.id)
    }

    @Test func theSameTurnInADifferentSessionIsItsOwnBookmark() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 4))
        store.add(bookmark(sessionB, 4))
        #expect(store.list().count == 2)
    }

    @Test func anUpdateKeepsThePositionItAlreadyHad() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1, "one"))
        store.add(bookmark(sessionA, 2, "two"))
        store.add(bookmark(sessionA, 1, "one again"))
        #expect(store.list().map(\.prompt) == ["one again", "two"])
    }

    @Test func lookupFindsABookmarkBySessionAndTurn() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 7, "seven"))
        #expect(store.bookmark(sessionID: sessionA, turn: 7)?.prompt == "seven")
        #expect(store.bookmark(sessionID: sessionA, turn: 8) == nil)
        #expect(store.bookmark(sessionID: sessionB, turn: 7) == nil)
    }

    @Test func removingOneLeavesTheRest() {
        var store = BookmarkStore()
        let doomed = store.add(bookmark(sessionA, 1))
        store.add(bookmark(sessionA, 2))
        store.add(bookmark(sessionB, 3))
        let removed = store.remove(id: doomed.id)
        #expect(removed)
        #expect(store.list().map(\.turn) == [2, 3])
    }

    @Test func removingAnUnknownIdChangesNothing() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))
        let removed = store.remove(id: UUID())
        #expect(!removed)
        #expect(store.list().count == 1)
    }

    @Test func droppingASessionDropsOnlyItsOwn() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))
        store.add(bookmark(sessionB, 2))
        store.add(bookmark(sessionA, 3))
        store.dropSession(sessionA)
        #expect(store.list().map(\.turn) == [2])
    }

    @Test func droppingASessionWithNoBookmarksChangesNothing() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))
        store.dropSession(sessionB)
        #expect(store.list().count == 1)
    }

    @Test func countForASessionIgnoresTheOthers() {
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))
        store.add(bookmark(sessionA, 2))
        store.add(bookmark(sessionB, 3))
        #expect(store.count(sessionID: sessionA) == 2)
        #expect(store.count(sessionID: sessionB) == 1)
        #expect(store.count(sessionID: UUID()) == 0)
    }

    @Test func encodeAndDecodeRestoresEveryField() throws {
        var store = BookmarkStore()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        store.add(bookmark(sessionA, 5, "keep every field", createdAt: created))
        store.add(bookmark(sessionB, 6, "and this one too", createdAt: created.addingTimeInterval(60)))

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(BookmarkStore.self, from: data)

        #expect(decoded == store)
        let restored = decoded.list().first
        #expect(restored?.id == store.list().first?.id)
        #expect(restored?.sessionID == sessionA)
        #expect(restored?.turn == 5)
        #expect(restored?.prompt == "keep every field")
        #expect(restored?.createdAt == created)
    }
}

struct BookmarkPersistenceTests {
    private let sessionA = UUID()
    private let sessionB = UUID()

    /// A fresh temp directory per test, so these never touch the real state dir and stay parallel-safe.
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-bookmarks-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bookmark(_ session: UUID, _ turn: Int, _ prompt: String = "prompt",
                          createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Bookmark {
        Bookmark(sessionID: session, turn: turn, prompt: prompt, createdAt: createdAt)
    }

    @Test func fileLivesBesideTheSnapshotUnderItsOwnName() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BookmarkPersistence(directory: directory)
        #expect(persistence.fileURL == directory.appendingPathComponent("bookmarks.json"))
    }

    @Test func aMissingFileLoadsEmpty() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(BookmarkPersistence(directory: directory).load() == BookmarkStore())
    }

    @Test func aMissingDirectoryLoadsEmpty() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-bookmarks-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(BookmarkPersistence(directory: directory).load() == BookmarkStore())
    }

    @Test func aCorruptFileLoadsEmpty() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BookmarkPersistence(directory: directory)
        try Data("{ not json at all".utf8).write(to: persistence.fileURL)
        #expect(persistence.load() == BookmarkStore())
    }

    @Test func saveThenLoadRoundTripsEveryField() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BookmarkPersistence(directory: directory)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var store = BookmarkStore()
        let first = store.add(bookmark(sessionA, 5, "keep every field", createdAt: created))
        store.add(bookmark(sessionB, 6, "and this one too", createdAt: created.addingTimeInterval(60)))

        try persistence.save(store)
        let loaded = persistence.load()

        #expect(loaded == store)
        #expect(loaded.list().first?.id == first.id)
        #expect(loaded.list().first?.createdAt == created)
        #expect(loaded.list().map(\.turn) == [5, 6])
    }

    @Test func savingCreatesTheDirectoryItNeeds() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("nested", isDirectory: true)
        let persistence = BookmarkPersistence(directory: directory)
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))

        try persistence.save(store)

        #expect(persistence.load() == store)
    }

    @Test func savingAnEmptyStoreClearsWhatWasThere() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BookmarkPersistence(directory: directory)
        var store = BookmarkStore()
        store.add(bookmark(sessionA, 1))
        try persistence.save(store)

        try persistence.save(BookmarkStore())

        #expect(persistence.load() == BookmarkStore())
    }
}

@MainActor
struct BookmarkCenterTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-bookmark-center-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func addAndRemovePersistAcrossReload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID()
        let center = BookmarkCenter(persistence: BookmarkPersistence(directory: directory))
        center.add(sessionID: session, turn: 3, prompt: "remember this")

        let reloaded = BookmarkCenter(persistence: BookmarkPersistence(directory: directory))
        #expect(reloaded.list(sessionID: session).map(\.turn) == [3])

        #expect(reloaded.remove(sessionID: session, turn: 3))
        #expect(BookmarkCenter(persistence: BookmarkPersistence(directory: directory)).list().isEmpty)
    }

    @Test func removingAMissingBookmarkAnswersFalseAndWritesNothing() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BookmarkPersistence(directory: directory)
        let center = BookmarkCenter(persistence: persistence)

        #expect(!center.remove(sessionID: UUID(), turn: 1))
        center.dropSession(UUID())

        #expect(!FileManager.default.fileExists(atPath: persistence.fileURL.path))
    }

    @Test func dropSessionPersistsTheDropAndKeepsOtherSessions() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let doomed = UUID()
        let survivor = UUID()
        let center = BookmarkCenter(persistence: BookmarkPersistence(directory: directory))
        center.add(sessionID: doomed, turn: 1, prompt: "a")
        center.add(sessionID: survivor, turn: 2, prompt: "b")

        center.dropSession(doomed)

        let reloaded = BookmarkCenter(persistence: BookmarkPersistence(directory: directory))
        #expect(reloaded.list().map(\.sessionID) == [survivor])
    }

    @Test func anInMemoryCenterWorksWithoutDisk() {
        let session = UUID()
        let center = BookmarkCenter()
        center.add(sessionID: session, turn: 1, prompt: "p")
        #expect(center.count(sessionID: session) == 1)
    }

    /// Turn numbers restart with the app while a restored session keeps its id, so without the run in the key
    /// today's turn 3 overwrote yesterday's — destroying the prompt, which after a restart is all that is left.
    @Test func aLaterRunsSameTurnDoesNotOverwriteAnEarlierBookmark() {
        let session = UUID()
        let yesterday = UUID(), today = UUID()
        var store = BookmarkStore()
        store.add(Bookmark(sessionID: session, turn: 3, run: yesterday, prompt: "the old question"))
        store.add(Bookmark(sessionID: session, turn: 3, run: today, prompt: "a different question"))

        let prompts = store.list(sessionID: session).map(\.prompt)
        #expect(prompts == ["the old question", "a different question"])
    }

    /// Within one run it is still a correction, not a second bookmark.
    @Test func theSameTurnInOneRunStillUpdatesInPlace() {
        let session = UUID(), run = UUID()
        var store = BookmarkStore()
        let first = store.add(Bookmark(sessionID: session, turn: 3, run: run, prompt: "first"))
        let second = store.add(Bookmark(sessionID: session, turn: 3, run: run, prompt: "corrected"))

        #expect(store.list(sessionID: session).count == 1)
        #expect(second.id == first.id)
        #expect(second.prompt == "corrected")
    }

    /// A record written before runs existed decodes with `run == nil` and is kept, never overwritten.
    @Test func aRunlessBookmarkIsHistoryAndSurvivesANewAdd() {
        let session = UUID()
        var store = BookmarkStore()
        store.add(Bookmark(sessionID: session, turn: 1, run: nil, prompt: "from an older build"))
        store.add(Bookmark(sessionID: session, turn: 1, run: UUID(), prompt: "from this build"))

        #expect(store.list(sessionID: session).map(\.prompt) == ["from an older build", "from this build"])
    }
}
