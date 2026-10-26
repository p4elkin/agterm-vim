import Foundation
import Testing
@testable import agtermCore

@MainActor
final class AppSessionRecencyTests {
    private let directory: URL
    private var persistence: AppSessionRecencyPersistence { AppSessionRecencyPersistence(directory: directory) }
    private var fileURL: URL { persistence.fileURL }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-apprecency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ text: String) throws {
        try Data(text.utf8).write(to: fileURL)
    }

    private func onDisk() -> [UUID]? {
        persistence.load()
    }

    @Test func aMissingFileLoadsEmptyAndFresh() {
        let recency = AppSessionRecency(persistence: persistence)

        #expect(recency.items.isEmpty)
        #expect(recency.isFresh)
    }

    @Test func aCorruptFileLoadsEmptyAndFresh() throws {
        try writeFile("{\"sessions\": [\"not-a-uuid\"]")

        let recency = AppSessionRecency(persistence: persistence)

        #expect(recency.items.isEmpty)
        #expect(recency.isFresh)
    }

    @Test func aValidFileLoadsInOrderIgnoringUnknownKeys() throws {
        let first = UUID(), second = UUID()
        try writeFile("{\"future\": 1, \"sessions\": [\"\(first)\", \"\(second)\"]}")

        let recency = AppSessionRecency(persistence: persistence)

        #expect(recency.items == [first, second])
        #expect(!recency.isFresh)
    }

    @Test func pushMovesAnIdToTheFrontAndWrites() {
        let first = UUID(), second = UUID()
        let recency = AppSessionRecency(persistence: persistence)

        recency.push(first)
        recency.push(second)
        recency.push(first)

        #expect(recency.items == [first, second])
        #expect(onDisk() == [first, second])
    }

    @Test func pushingTheCurrentFrontWritesNothing() throws {
        let id = UUID()
        let recency = AppSessionRecency(persistence: persistence)
        recency.push(id)
        try FileManager.default.removeItem(at: fileURL)

        recency.push(id)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func forgetOfAKnownIdRemovesAndWrites() {
        let kept = UUID(), gone = UUID()
        let recency = AppSessionRecency(persistence: persistence)
        recency.push(kept)
        recency.push(gone)

        recency.forget([gone])

        #expect(recency.items == [kept])
        #expect(onDisk() == [kept])
    }

    @Test func forgetOfUnknownIdsWritesNothing() throws {
        let id = UUID()
        let recency = AppSessionRecency(persistence: persistence)
        recency.push(id)
        try FileManager.default.removeItem(at: fileURL)

        recency.forget([UUID(), UUID()])

        #expect(recency.items == [id])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func theListKeepsAtMostOneHundred() {
        let ids = (0..<101).map { _ in UUID() }
        let recency = AppSessionRecency(persistence: persistence)

        ids.forEach(recency.push)

        #expect(recency.items.count == 100)
        #expect(recency.items.first == ids.last)
        #expect(!recency.items.contains(ids[0]))
        #expect(onDisk()?.count == 100)
    }

    @Test func seedFillsAFreshListAndWrites() {
        let first = UUID(), second = UUID()
        let recency = AppSessionRecency(persistence: persistence)

        recency.seed([first, second])

        #expect(recency.items == [first, second])
        #expect(!recency.isFresh)
        #expect(onDisk() == [first, second])
    }

    @Test func seedKeepsIdsPushedBeforeItInFront() {
        let pushed = UUID(), seeded = UUID()
        let recency = AppSessionRecency(persistence: persistence)
        recency.push(pushed)

        recency.seed([seeded, pushed])

        #expect(recency.items == [pushed, seeded])
    }

    @Test func seedOnAListLoadedFromAValidFileDoesNothing() throws {
        let stored = UUID()
        try writeFile("{\"sessions\": [\"\(stored)\"]}")
        let recency = AppSessionRecency(persistence: persistence)

        recency.seed([UUID()])

        #expect(recency.items == [stored])
        #expect(onDisk() == [stored])
    }

    @Test func aFailedWriteKeepsTheInMemoryList() throws {
        let id = UUID()
        let recency = AppSessionRecency(persistence: persistence)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        recency.push(id)

        #expect(recency.items == [id])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func aControlRecentSessionEncodesSessionAndWindowAndRoundTrips() throws {
        let entry = ControlRecentSession(session: "s-1", window: "w-1")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let data = try encoder.encode(entry)

        #expect(String(decoding: data, as: UTF8.self) == "{\"session\":\"s-1\",\"window\":\"w-1\"}")
        #expect(try JSONDecoder().decode(ControlRecentSession.self, from: data) == entry)
    }
}
