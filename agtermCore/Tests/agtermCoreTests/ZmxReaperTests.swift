import Foundation
import Testing
@testable import agtermCore

struct ZmxReaperTests {
    private func session(_ id: UUID, isSplit: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: id, customName: nil, cwd: "/a", isSplit: isSplit ? true : nil)
    }

    private func snapshot(_ sessions: [SessionSnapshot]) -> Snapshot {
        Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: sessions)])
    }

    private func entry(_ name: String, clients: Int?) -> ZmxListParser.Entry {
        ZmxListParser.Entry(name: name, clients: clients, leaderPID: 4242)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-reap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - the claimed set

    @Test func claimedKeysCoverBothPanesOfEverySessionAcrossWindows() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let claimed = ZmxReaper.claimedKeys(from: [
            snapshot([session(first), session(second, isSplit: true)]),
            snapshot([session(third)])
        ])
        #expect(claimed == Set([first, second, third].flatMap {
            ["\($0.uuidString)-left", "\($0.uuidString)-right"]
        }))
    }

    /// An unsplit row claims its right key too: a daemon that is not there costs nothing to spare, and the
    /// split may have been closed after the snapshot was written.
    @Test func claimedKeysCoverTheRightPaneOfAnUnsplitRow() {
        let id = UUID()
        #expect(ZmxReaper.claimedKeys(from: [snapshot([session(id)])]).contains("\(id.uuidString)-right"))
    }

    @Test func claimedKeysAreEmptyWithoutSessions() {
        #expect(ZmxReaper.claimedKeys(from: []).isEmpty)
        #expect(ZmxReaper.claimedKeys(from: [Snapshot()]).isEmpty)
    }

    // MARK: - orphan selection

    @Test func orphansAreZeroClientOwnedNamesNothingClaims() {
        let id = UUID()
        let listing = [entry("\(id.uuidString)-left", clients: 0)]
        #expect(ZmxReaper.orphans(in: listing, claimed: []) == ["\(id.uuidString)-left"])
    }

    @Test func orphansSpareAnUnknownClientCount() {
        let listing = [entry("\(UUID().uuidString)-left", clients: nil)]
        #expect(ZmxReaper.orphans(in: listing, claimed: []).isEmpty)
    }

    @Test func orphansSpareAnAttachedSession() {
        let listing = [entry("\(UUID().uuidString)-right", clients: 1)]
        #expect(ZmxReaper.orphans(in: listing, claimed: []).isEmpty)
    }

    @Test func orphansSpareAClaimedName() {
        let id = UUID()
        let listing = [entry("\(id.uuidString)-left", clients: 0), entry("\(id.uuidString)-right", clients: 0)]
        let claimed = ZmxReaper.claimedKeys(from: [snapshot([session(id)])])
        #expect(ZmxReaper.orphans(in: listing, claimed: claimed).isEmpty)
    }

    @Test func orphansSpareAForeignName() {
        let listing = [entry("mctl", clients: 0), entry("\(UUID().uuidString)-mirror", clients: 0),
                       entry("not-a-uuid-left", clients: 0)]
        #expect(ZmxReaper.orphans(in: listing, claimed: []).isEmpty)
    }

    /// A daemon the outside tooling left under a scratch or overlay role is agterm's and reapable, even
    /// though the app itself never wraps those surfaces.
    @Test func orphansIncludeAScratchRoleLeftBehind() {
        let id = UUID()
        #expect(ZmxReaper.orphans(in: [entry("\(id.uuidString)-scratch", clients: 0)], claimed: [])
            == ["\(id.uuidString)-scratch"])
    }

    @Test func anEmptyListingYieldsNoOrphans() {
        #expect(ZmxReaper.orphans(in: [], claimed: []).isEmpty)
    }

    // MARK: - the persisted claim

    @Test func persistedSnapshotsReadEveryWindowFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = directory.appendingPathComponent("windows", isDirectory: true)
        let first = UUID()
        let second = UUID()
        try PersistenceStore(directory: windows, fileName: "\(UUID().uuidString).json").save(snapshot([session(first)]))
        try PersistenceStore(directory: windows, fileName: "\(UUID().uuidString).json").save(snapshot([session(second)]))
        let snapshots = try #require(ZmxReaper.persistedSnapshots(directory: directory))
        #expect(ZmxReaper.claimedKeys(from: snapshots).contains("\(first.uuidString)-left"))
        #expect(ZmxReaper.claimedKeys(from: snapshots).contains("\(second.uuidString)-left"))
    }

    @Test func persistedSnapshotsAreUnknownWithoutAWindowsDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ZmxReaper.persistedSnapshots(directory: directory) == nil)
    }

    /// ⚠️ One unreadable window file makes the whole claim unknown. Treating it as an empty window would
    /// leave every session it holds unclaimed, and the reap would kill their agents.
    @Test func persistedSnapshotsAreUnknownWhenAFileDoesNotDecode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = directory.appendingPathComponent("windows", isDirectory: true)
        try PersistenceStore(directory: windows, fileName: "\(UUID().uuidString).json").save(snapshot([session(UUID())]))
        try Data("{ not json".utf8).write(to: windows.appendingPathComponent("\(UUID().uuidString).json"))
        #expect(ZmxReaper.persistedSnapshots(directory: directory) == nil)
    }

    @Test func persistedSnapshotsAreUnknownOnAVersionMismatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = directory.appendingPathComponent("windows", isDirectory: true)
        var future = snapshot([session(UUID())])
        future.version = Snapshot.currentVersion + 1
        try PersistenceStore(directory: windows, fileName: "\(UUID().uuidString).json").save(future)
        #expect(ZmxReaper.persistedSnapshots(directory: directory) == nil)
    }

    @Test func persistedSnapshotsIgnoreNonSnapshotFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = directory.appendingPathComponent("windows", isDirectory: true)
        let id = UUID()
        try PersistenceStore(directory: windows, fileName: "\(UUID().uuidString).json").save(snapshot([session(id)]))
        try Data("junk".utf8).write(to: windows.appendingPathComponent(".DS_Store"))
        let snapshots = try #require(ZmxReaper.persistedSnapshots(directory: directory))
        #expect(ZmxReaper.claimedKeys(from: snapshots) == ["\(id.uuidString)-left", "\(id.uuidString)-right"])
    }
}
