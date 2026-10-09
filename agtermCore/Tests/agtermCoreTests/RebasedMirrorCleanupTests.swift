import Foundation
import Testing
@testable import agtermCore

struct RebasedMirrorCleanupTests {
    @Test(arguments: [
        ("/Users/sasha/Library/Application Support/agterm/rebased/mirrors/p4linux/40eee01ce47c7996/jackrabbit-review-chm",
         "d54f62e6"),
        ("/tmp/agide-jr", "226f9a98"),
        ("/tmp/m/ec148cb48e73ca47/repo", "a3bf390"),
    ])
    func hashesAPathAsJavaStringHashCodePrintsIt(_ path: String, _ hash: String) {
        #expect(RebasedMirrorCleanup.javaHash(path) == hash)
    }

    @Test(arguments: ["jackrabbit-review-chm.d54f62e6", "jackrabbit-review-chm-d54f62e6", "jackrab_d54f62e6_78d80aa",
                      "d54f62e6.2_i.len"])
    func aNameHoldingTheHashAsATokenMatches(_ name: String) {
        #expect(RebasedMirrorCleanup.names(name, hash: "d54f62e6"))
    }

    @Test(arguments: ["xd54f62e6", "d54f62e67", "jackrabbit-review-chm", ""])
    func aNameWithoutTheHashAsATokenDoesNot(_ name: String) {
        #expect(!RebasedMirrorCleanup.names(name, hash: "d54f62e6"))
    }

    @Test func aShortHashAlsoMatchesItsZeroPaddedForm() {
        #expect(RebasedMirrorCleanup.names("repo.a3bf390", hash: "a3bf390"))
        #expect(RebasedMirrorCleanup.names("repo.0a3bf390", hash: "a3bf390"))
    }

    @Test func theWalkOpensOnlyThePerProjectDirectories() throws {
        let system = try Self.temporaryDirectory().appendingPathComponent("system", isDirectory: true)
        let hash = "d54f62e6"
        let wanted = ["projects/jr.\(hash)", "editor/jr-\(hash)", "compiler/jr.\(hash)", "vcs-log/jr_\(hash)_78d80aa",
                      "vcs-users/\(hash).len", "frameworks/detection/jr.\(hash)"]
        let shared = ["index/jr.\(hash)", "caches/jr.\(hash)", "LocalHistory/jr.\(hash)", "plugins/jr.\(hash)",
                      "compile-server/jr_\(hash)", "projects/other.226f9a98"]
        for path in wanted + shared {
            try FileManager.default.createDirectory(at: system.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let found = RebasedMirrorCleanup.ideEntries(hash: hash, systemDirectory: system)
            .map { String($0.path.dropFirst(system.path.count + 1)) }
        #expect(found == wanted.sorted())
    }

    @Test func aMissingSystemDirectoryHasNoEntries() throws {
        let missing = try Self.temporaryDirectory().appendingPathComponent("system", isDirectory: true)
        #expect(RebasedMirrorCleanup.ideEntries(hash: "d54f62e6", systemDirectory: missing).isEmpty)
    }

    #if canImport(Darwin)
    @Test func aCloneUnderPrivateTmpHasTheProjectPathItsTmpSpellingHas() throws {
        let name = "agterm-mirror-cleanup-\(UUID().uuidString)"
        let clone = URL(fileURLWithPath: "/private/tmp/\(name)/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let path = RebasedMirrorCleanup.projectPath(clone)
        #expect(path == RebasedMirrorCleanup.projectPath(URL(fileURLWithPath: "/tmp/\(name)/repo", isDirectory: true)))

        let system = try Self.temporaryDirectory().appendingPathComponent("system", isDirectory: true)
        let entry = system.appendingPathComponent("projects/repo.\(RebasedMirrorCleanup.javaHash(path))")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        #expect(RebasedMirrorCleanup.ideEntries(projectPath: path, systemDirectory: system).map(\.lastPathComponent)
                == [entry.lastPathComponent])
    }
    #endif

    @Test func aCloneUnderMirrorsAnswersItsHashDirectory() throws {
        let state = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let (hashDirectory, clone) = try Self.mirror(in: state)
        let found = RebasedMirrorCleanup.hashDirectory(ofClone: clone, stateDirectory: state)
        #expect(found?.path == RebasedMirrorCleanup.projectPath(hashDirectory))
    }

    @Test func aPathThatIsNotAMirrorCloneAnswersNil() throws {
        let state = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: state) }
        let (hashDirectory, _) = try Self.mirror(in: state)
        let outside = state.appendingPathComponent("rebased/other/p4linux/40eee01ce47c7996/repo", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        for path in [URL(fileURLWithPath: "/tmp", isDirectory: true), hashDirectory, outside] {
            #expect(RebasedMirrorCleanup.hashDirectory(ofClone: path, stateDirectory: state) == nil)
        }
    }

    #if canImport(Darwin)
    @Test func aCloneSpelledThroughPrivateAnswersTheSameHashDirectory() throws {
        let state = URL(fileURLWithPath: "/tmp/agterm-mirror-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let (_, clone) = try Self.mirror(in: state)
        let privateClone = URL(fileURLWithPath: "/private" + clone.path, isDirectory: true)
        let found = RebasedMirrorCleanup.hashDirectory(ofClone: privateClone, stateDirectory: state)
        #expect(found != nil)
        #expect(found == RebasedMirrorCleanup.hashDirectory(ofClone: clone, stateDirectory: state))
    }
    #endif

    private static let day: TimeInterval = 86_400
    private static let opened = Date(timeIntervalSince1970: 1_791_000_000)

    /// `<state>/rebased/mirrors/<host>/<hash>/<name>`, its marker and `FETCH_HEAD` when given, ages set last.
    @discardableResult
    static func mirror(in state: URL, host: String = "p4linux", hash: String = "40eee01ce47c7996", name: String? = "repo",
                       marker: Date? = nil, fetchHead: Date? = nil, hashModified: Date = opened.addingTimeInterval(-30 * day))
        throws -> (hashDirectory: URL, clone: URL) {
        let fileManager = FileManager.default
        let hashDirectory = state.appendingPathComponent("rebased/mirrors/\(host)/\(hash)", isDirectory: true)
        try fileManager.createDirectory(at: hashDirectory, withIntermediateDirectories: true)
        let clone = name.map { hashDirectory.appendingPathComponent($0, isDirectory: true) } ?? hashDirectory
        if name != nil { try fileManager.createDirectory(at: clone, withIntermediateDirectories: true) }
        if let marker {
            try RebasedMirrorMarker(source: "\(host):/home/s/\(name ?? "repo")", lastOpened: marker).write(to: hashDirectory)
        }
        if let fetchHead {
            let git = clone.appendingPathComponent(".git", isDirectory: true)
            try fileManager.createDirectory(at: git, withIntermediateDirectories: true)
            let file = git.appendingPathComponent("FETCH_HEAD")
            try Data("x".utf8).write(to: file)
            try fileManager.setAttributes([.modificationDate: fetchHead], ofItemAtPath: file.path)
        }
        try fileManager.setAttributes([.modificationDate: hashModified], ofItemAtPath: hashDirectory.path)
        return (hashDirectory, clone)
    }

    @Test func aFreshMarkerGivesItsTime() throws {
        let state = try Self.temporaryDirectory()
        let (hashDirectory, clone) = try Self.mirror(in: state, marker: Self.opened, fetchHead: Self.opened.addingTimeInterval(-9 * Self.day))
        let records = RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: false)
        #expect(records == [RebasedMirrorRecord(host: "p4linux", source: "p4linux:/home/s/repo", clone: clone,
                                                hashDirectory: hashDirectory, lastOpened: Self.opened, bytes: nil, inUse: false)])
    }

    @Test func aFetchNewerThanTheMarkerGivesTheFetchsTime() throws {
        let state = try Self.temporaryDirectory()
        try Self.mirror(in: state, marker: Self.opened.addingTimeInterval(-9 * Self.day), fetchHead: Self.opened,
                        hashModified: Self.opened.addingTimeInterval(Self.day))
        let record = try #require(RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: false).first)
        #expect(record.lastOpened == Self.opened)
        #expect(record.source == "p4linux:/home/s/repo")
    }

    @Test func noMarkerGivesTheFetchsTimeAndNoSource() throws {
        let state = try Self.temporaryDirectory()
        try Self.mirror(in: state, fetchHead: Self.opened)
        let record = try #require(RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: false).first)
        #expect(record.lastOpened == Self.opened)
        #expect(record.source == nil)
    }

    @Test func neitherGivesTheHashDirectorysTime() throws {
        let state = try Self.temporaryDirectory()
        try Self.mirror(in: state, hashModified: Self.opened)
        let (empty, _) = try Self.mirror(in: state, hash: "ec148cb48e73ca47", name: nil, hashModified: Self.opened)
        let records = RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: false)
        #expect(records.map(\.lastOpened) == [Self.opened, Self.opened])
        #expect(records.last?.clone == empty)
    }

    @Test func aSymlinkedHostOrHashIsSkipped() throws {
        let state = try Self.temporaryDirectory()
        let (kept, _) = try Self.mirror(in: state)
        let elsewhere = try Self.temporaryDirectory()
        let (outside, _) = try Self.mirror(in: elsewhere, host: "other")
        let mirrors = state.appendingPathComponent("rebased/mirrors", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: mirrors.appendingPathComponent("linked"),
                                                   withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: kept.deletingLastPathComponent().appendingPathComponent("ec148cb48e73ca47"),
                                                   withDestinationURL: outside)
        #expect(RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: false).map(\.hashDirectory) == [kept])
    }

    @Test func aCloneInTheSetIsInUse() throws {
        let state = try Self.temporaryDirectory()
        let (_, used) = try Self.mirror(in: state, hash: "40eee01ce47c7996")
        try Self.mirror(in: state, hash: "ec148cb48e73ca47")
        let alias = try Self.temporaryDirectory().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: state)
        let records = RebasedMirrorCleanup.scan(stateDirectory: alias, inUse: [RebasedMirrorCleanup.projectPath(used)], measure: false)
        #expect(records.map(\.inUse) == [true, false])
    }

    @Test func aMirrorRemovedWhileTheWalkRunsDoesNotFailTheScan() throws {
        let state = try Self.temporaryDirectory()
        let (gone, _) = try Self.mirror(in: state, hash: "40eee01ce47c7996", fetchHead: Self.opened)
        let (kept, _) = try Self.mirror(in: state, hash: "ec148cb48e73ca47", fetchHead: Self.opened)
        let records = RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: true) { _ in
            try? FileManager.default.removeItem(at: gone)
        }
        #expect(records.map(\.hashDirectory) == [kept])
    }

    @Test func theSizeSumsTheFilesWithoutFollowingSymlinks() throws {
        let state = try Self.temporaryDirectory()
        let (_, clone) = try Self.mirror(in: state)
        try Data(count: 100).write(to: clone.appendingPathComponent("a"))
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("d"), withIntermediateDirectories: true)
        try Data(count: 20).write(to: clone.appendingPathComponent("d/b"))
        let large = try Self.temporaryDirectory().appendingPathComponent("large")
        try Data(count: 10_000).write(to: large)
        try FileManager.default.createSymbolicLink(at: clone.appendingPathComponent("link"), withDestinationURL: large)
        try FileManager.default.createSymbolicLink(at: clone.appendingPathComponent("dirlink"),
                                                   withDestinationURL: large.deletingLastPathComponent())
        #expect(RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: true).map(\.bytes) == [120])
        #expect(RebasedMirrorCleanup.scan(stateDirectory: state, inUse: [], measure: false).map(\.bytes) == [nil])
    }

    @Test func noMirrorsDirectoryScansEmpty() throws {
        #expect(RebasedMirrorCleanup.scan(stateDirectory: try Self.temporaryDirectory(), inUse: [], measure: true).isEmpty)
    }

    typealias Mirror = (hashDirectory: URL, clone: URL)

    struct PruneFixture {
        let state: URL
        let stale: Mirror
        let fresh: Mirror
        let used: Mirror

        var system: URL { state.appendingPathComponent("rebased/system", isDirectory: true) }
        var emptyHost: URL { state.appendingPathComponent("rebased/mirrors/empty-host", isDirectory: true) }

        func ideData(_ mirror: Mirror) -> [URL] {
            let hash = RebasedMirrorCleanup.javaHash(RebasedMirrorCleanup.projectPath(mirror.clone))
            return ["editor/repo-\(hash)", "projects/repo.\(hash)"].map { system.appendingPathComponent($0) }
        }

        func request(dryRun: Bool, maxAgeDays: Int = 7) -> RebasedMirrorCleanup.Request {
            .init(stateDirectory: state, inUse: [RebasedMirrorCleanup.projectPath(used.clone)], maxAgeDays: maxAgeDays,
                  dryRun: dryRun, now: opened)
        }

        /// Every file under the directories the IDE shares between projects, with its bytes.
        func shared() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for directory in ["index", "caches", "LocalHistory", "compile-server"] {
                let parent = system.appendingPathComponent(directory)
                for name in try FileManager.default.contentsOfDirectory(atPath: parent.path) {
                    files["\(directory)/\(name)"] = try Data(contentsOf: parent.appendingPathComponent(name))
                }
            }
            return files
        }
    }

    /// Three mirrors on one host, stale, fresh and stale-but-in-use, each with IDE entries, plus an empty host.
    static func pruneFixture() throws -> PruneFixture {
        let state = try temporaryDirectory()
        let fixture = PruneFixture(
            state: state,
            stale: try mirror(in: state, hash: "a0", marker: opened.addingTimeInterval(-30 * day)),
            fresh: try mirror(in: state, hash: "b0", marker: opened.addingTimeInterval(-3600)),
            used: try mirror(in: state, hash: "c0", marker: opened.addingTimeInterval(-30 * day)))
        try FileManager.default.createDirectory(at: fixture.emptyHost, withIntermediateDirectories: true)
        for mirror in [fixture.stale, fixture.fresh, fixture.used] {
            for entry in fixture.ideData(mirror) {
                try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
                try Data("state".utf8).write(to: entry.appendingPathComponent("workspace.xml"))
            }
            let hash = RebasedMirrorCleanup.javaHash(RebasedMirrorCleanup.projectPath(mirror.clone))
            for path in ["index/repo.\(hash)", "caches/repo.\(hash)", "LocalHistory/repo.\(hash)", "compile-server/repo_\(hash)"] {
                let file = fixture.system.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("shared \(path)".utf8).write(to: file)
            }
        }
        return fixture
    }

    static func tree(_ root: URL) -> [String] {
        let walk = FileManager.default.enumerator(atPath: root.path)
        return (walk?.allObjects as? [String] ?? []).sorted()
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func aDryRunDeletesNothingAndReportsTheStaleMirrorWithItsIDEData() throws {
        let fixture = try Self.pruneFixture()
        let before = Self.tree(fixture.state)
        let report = RebasedMirrorCleanup.prune(fixture.request(dryRun: true))
        #expect(Self.tree(fixture.state) == before)
        #expect(Self.exists(fixture.emptyHost))
        #expect(report.dryRun)
        #expect(report.olderThanDays == 7)
        #expect(report.removed.map(\.mirror.hashDirectory) == [fixture.stale.hashDirectory])
        #expect(report.removed.map { $0.ideData.map(\.path) } == [fixture.ideData(fixture.stale).map(\.path)])
        #expect(report.kept.map(\.mirror.hashDirectory) == [fixture.used.hashDirectory])
    }

    @Test func aRealRunRemovesOnlyTheStaleMirrorAndItsIDEData() throws {
        let fixture = try Self.pruneFixture()
        let shared = try fixture.shared()
        let report = RebasedMirrorCleanup.prune(fixture.request(dryRun: false))
        #expect(!Self.exists(fixture.stale.hashDirectory))
        #expect(fixture.ideData(fixture.stale).allSatisfy { !Self.exists($0) })
        for kept in [fixture.fresh, fixture.used] {
            #expect(Self.exists(kept.clone))
            #expect(fixture.ideData(kept).allSatisfy(Self.exists))
        }
        #expect(try fixture.shared() == shared)
        #expect(!Self.exists(fixture.emptyHost))
        #expect(report.removed.map(\.mirror.hashDirectory) == [fixture.stale.hashDirectory])
        #expect(report.removed.map { $0.ideData.map(\.path) } == [fixture.ideData(fixture.stale).map(\.path)])
        let kept = try #require(report.kept.first)
        #expect(report.kept.count == 1)
        #expect(kept.mirror.hashDirectory == fixture.used.hashDirectory)
        #expect(kept.mirror.inUse)
        #expect(kept.error == nil)
    }

    @Test func aMarkerMinutesOldIsSkippedAtOneDay() throws {
        let state = try Self.temporaryDirectory()
        let (hashDirectory, _) = try Self.mirror(in: state, marker: Self.opened.addingTimeInterval(-300))
        let report = RebasedMirrorCleanup.prune(.init(stateDirectory: state, inUse: [], maxAgeDays: 1, dryRun: false, now: Self.opened))
        #expect(Self.exists(hashDirectory))
        #expect(report.removed.isEmpty && report.kept.isEmpty)
    }

    @Test func aMarkerRewrittenBeforeTheDeleteSkipsTheMirror() throws {
        let fixture = try Self.pruneFixture()
        let report = RebasedMirrorCleanup.prune(fixture.request(dryRun: false)) { record in
            try? RebasedMirrorMarker(source: "p4linux:/home/s/repo", lastOpened: Self.opened).write(to: record.hashDirectory)
        }
        #expect(Self.exists(fixture.stale.clone))
        #expect(fixture.ideData(fixture.stale).allSatisfy(Self.exists))
        #expect(report.removed.isEmpty)
        #expect(report.kept.map(\.mirror.hashDirectory) == [fixture.used.hashDirectory])
    }

    @Test func theLastMirrorOfAHostTakesTheHostAndAnotherFileKeepsIt() throws {
        let state = try Self.temporaryDirectory()
        let stale = Self.opened.addingTimeInterval(-30 * Self.day)
        let (alone, _) = try Self.mirror(in: state, host: "p4linux", marker: stale)
        let (beside, _) = try Self.mirror(in: state, host: "p4air", marker: stale)
        let other = beside.deletingLastPathComponent().appendingPathComponent(".DS_Store")
        try Data("x".utf8).write(to: other)
        let report = RebasedMirrorCleanup.prune(.init(stateDirectory: state, inUse: [], maxAgeDays: 7, dryRun: false, now: Self.opened))
        #expect(report.removed.count == 2)
        #expect(!Self.exists(alone.deletingLastPathComponent()))
        #expect(!Self.exists(beside))
        #expect(Self.exists(other))
    }

    @Test func aHashDirectoryRemovedBeforeTheDeleteIsSkippedWithoutError() throws {
        let fixture = try Self.pruneFixture()
        let report = RebasedMirrorCleanup.prune(fixture.request(dryRun: false)) { record in
            try? FileManager.default.removeItem(at: record.hashDirectory)
        }
        #expect(report.removed.isEmpty)
        #expect(report.kept.map(\.mirror.hashDirectory) == [fixture.used.hashDirectory])
        #expect(report.kept.allSatisfy { $0.error == nil })
    }

    @Test func aRemovalThatFailsKeepsTheMirrorWithAnErrorAfterItsIDEData() throws {
        let state = try Self.temporaryDirectory()
        let mirror = try Self.mirror(in: state, marker: Self.opened.addingTimeInterval(-30 * Self.day))
        let hash = RebasedMirrorCleanup.javaHash(RebasedMirrorCleanup.projectPath(mirror.clone))
        let entry = state.appendingPathComponent("rebased/system/projects/repo.\(hash)")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let host = mirror.hashDirectory.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: host.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path) }
        let report = RebasedMirrorCleanup.prune(.init(stateDirectory: state, inUse: [], maxAgeDays: 7, dryRun: false, now: Self.opened))
        let kept = try #require(report.kept.first)
        #expect(report.removed.isEmpty)
        #expect(kept.mirror.hashDirectory == mirror.hashDirectory)
        #expect(kept.error != nil)
        #expect(kept.ideData.map(\.path) == [entry.path])
        #expect(!Self.exists(entry))
        #expect(Self.exists(mirror.hashDirectory))
    }

    @Test func nothingOutsideMirrorsOrSystemIsDeleted() throws {
        let fixture = try Self.pruneFixture()
        let outside = try Self.temporaryDirectory()
        let hash = RebasedMirrorCleanup.javaHash(RebasedMirrorCleanup.projectPath(fixture.stale.clone))
        let foreign = outside.appendingPathComponent("vcs-log/repo.\(hash)")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.system.appendingPathComponent("vcs-log"),
                                                   withDestinationURL: foreign.deletingLastPathComponent())
        let (outsideMirror, _) = try Self.mirror(in: outside, hash: "d0", marker: Self.opened.addingTimeInterval(-30 * Self.day))
        try FileManager.default.createSymbolicLink(at: fixture.stale.hashDirectory.deletingLastPathComponent().appendingPathComponent("d0"),
                                                   withDestinationURL: outsideMirror)
        let report = RebasedMirrorCleanup.prune(fixture.request(dryRun: false))
        #expect(Self.exists(foreign))
        #expect(Self.exists(outsideMirror))
        #expect(report.removed.map { $0.ideData.map(\.path) } == [fixture.ideData(fixture.stale).map(\.path)])
    }

    @Test func aReportMapsDatesToEpochSecondsAndKeepsIDEDataAndErrors() {
        let record = RebasedMirrorRecord(host: "p4linux", source: "p4linux:/home/s/repo", clone: URL(fileURLWithPath: "/s/a0/repo"),
                                         hashDirectory: URL(fileURLWithPath: "/s/a0"), lastOpened: Self.opened, bytes: 120, inUse: false)
        let report = RebasedMirrorCleanup.Report(
            removed: [.init(mirror: record, ideData: [URL(fileURLWithPath: "/s/system/projects/repo.1")], error: nil)],
            kept: [.init(mirror: record, ideData: [], error: "denied")], dryRun: true, olderThanDays: 7)
        let payload = ControlRebasedMirrors(report: report)
        #expect(payload.mirrors == nil)
        #expect(payload.dryRun == true)
        #expect(payload.olderThanDays == 7)
        #expect(payload.removed == [ControlRebasedMirrorNode(host: "p4linux", source: "p4linux:/home/s/repo", directory: "/s/a0/repo",
                                                             lastOpened: 1_791_000_000, bytes: 120, inUse: false,
                                                             ideData: ["/s/system/projects/repo.1"])])
        #expect(payload.kept?.map(\.error) == ["denied"])
    }

    @Test func aListMapsBytesAndInUse() {
        let record = RebasedMirrorRecord(host: "p4linux", source: nil, clone: URL(fileURLWithPath: "/s/a0/repo"),
                                         hashDirectory: URL(fileURLWithPath: "/s/a0"), lastOpened: Self.opened, bytes: 120, inUse: true)
        let payload = ControlRebasedMirrors(mirrors: [record])
        #expect(payload.mirrors == [ControlRebasedMirrorNode(host: "p4linux", directory: "/s/a0/repo", lastOpened: 1_791_000_000,
                                                             bytes: 120, inUse: true)])
        #expect(payload.removed == nil && payload.kept == nil && payload.dryRun == nil)
        #expect(ControlRebasedMirrors(mirrors: []).mirrors == [])
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-mirror-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
