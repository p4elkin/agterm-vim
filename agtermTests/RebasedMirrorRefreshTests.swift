import Foundation
import XCTest
import agtermCore
@testable import agterm

final class RebasedMirrorRefreshTests: XCTestCase {
    private var stateDirectory: URL!
    private let mirror = RebasedMirror(host: "p4linux", path: "/home/s/repo/sub")!
    private let top = "/home/s/repo"

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private var hashDirectory: URL {
        mirror.directory(top: top, stateDirectory: stateDirectory).deletingLastPathComponent()
    }

    /// Answers the ssh query with `top`, then each git step with the next status in `steps`.
    private func fake(query: Int32 = 0, steps: [Int32] = [0, 0, 0]) -> ([String], TimeInterval) -> RebasedMirrorRefresh.Outcome {
        var remaining = steps
        return { [top] argv, _ in
            if argv.first == "/usr/bin/ssh" {
                return RebasedMirrorRefresh.Outcome(status: query, stdout: query == 0 ? top + "\n" : "", reason: "exit \(query)")
            }
            let status = remaining.isEmpty ? 0 : remaining.removeFirst()
            return RebasedMirrorRefresh.Outcome(status: status, stdout: "", reason: "exit \(status)")
        }
    }

    func testAFetchThatFailsMidwayStillLeavesTheMarkerWrittenAfterTheDirectory() {
        let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: .none, execute: fake(steps: [0, 1]))
        guard case .failure = result else { return XCTFail("the fetch failed, so the refresh fails: \(result)") }
        XCTAssertEqual(RebasedMirrorMarker.read(from: hashDirectory)?.source, "p4linux:/home/s/repo")
    }

    func testAFailedSshQueryLeavesAnExistingMarkerUnchanged() throws {
        try FileManager.default.createDirectory(at: hashDirectory, withIntermediateDirectories: true)
        let old = RebasedMirrorMarker(source: "p4linux:/home/s/repo", lastOpened: Date(timeIntervalSince1970: 1_791_000_000))
        try old.write(to: hashDirectory)
        let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: .none, execute: fake(query: 255))
        guard case .failure = result else { return XCTFail("the query failed, so the refresh fails: \(result)") }
        XCTAssertEqual(RebasedMirrorMarker.read(from: hashDirectory), old)
    }

    func testASuccessfulRefreshLeavesAMarkerNoOlderThanItsStart() throws {
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let steps = fake()
        let firstMarker = hashDirectory.appendingPathComponent(RebasedMirrorMarker.fileName)
        // drops the marker written before the fetch, so only the write after the last step can leave one
        let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: .none) { argv, timeout in
            if argv.contains("checkout") { try? FileManager.default.removeItem(at: firstMarker) }
            return steps(argv, timeout)
        }
        XCTAssertEqual(try result.get().source, "p4linux:/home/s/repo")
        let marker = try XCTUnwrap(RebasedMirrorMarker.read(from: hashDirectory))
        XCTAssertEqual(marker.source, "p4linux:/home/s/repo")
        XCTAssertGreaterThanOrEqual(marker.lastOpened, start)
    }

    // MARK: Synced

    private var state: String { RebasedMirrorSync.stateID(stateDirectory: stateDirectory) }
    private var treeName: String { RebasedMirrorSync.treeName(state: state, host: "p4linux", top: top) }
    private var m2Name: String { RebasedMirrorSync.m2Name(state: state, host: "p4linux") }
    private var clone: URL { mirror.directory(top: top, stateDirectory: stateDirectory) }
    private var m2: URL { RebasedMirrorSync.m2Directory(host: "p4linux", stateDirectory: stateDirectory) }

    private func listed(_ name: String, kind: String = "tree", status: String = "watching", paused: Bool = false,
                        files: (Int, Int) = (3, 3), problems: String = "", conflicts: [String] = []) -> String {
        let conflictList = conflicts.map { #"{"root": "\#($0)"}"# }.joined(separator: ",")
        return #"{"name": "\#(name)", "labels": {"agterm-kind": "\#(kind)"}, "status": "\#(status)", "paused": \#(paused), "#
            + #""alpha": {"path": "a", "files": \#(files.0)}, "beta": {"path": "b", "files": \#(files.1)\#(problems)}, "#
            + #""conflicts": [\#(conflictList)]}"#
    }

    private func both(tree: String? = nil) -> String { "[\(tree ?? listed(treeName)), \(listed(m2Name, kind: "m2"))]" }

    func testWithNoBinaryTheRefreshChecksOutAsBeforeWithPerStepTimeouts() {
        let steps = Recorder<String>()
        let fake = fake()
        _ = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: .none) { argv, timeout in
            if argv.first == "/usr/bin/git" { steps.append("\(argv[1] == "-C" ? argv[3] : argv[1]) \(Int(timeout))") }
            return fake(argv, timeout)
        }
        XCTAssertEqual(steps.items, ["init 30", "fetch 300", "checkout 300"])
    }

    func testAnExistingMirrorWithNoSessionGetsBothSessionsCreatedThenFlushed() throws {
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".idea"), withIntermediateDirectories: true)
        for name in ["a.txt", ".git/config", ".idea/ws.xml"] {
            try "x".write(to: clone.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let sync = FakeSync(lists: ["[]", both()])
        var gitSteps: [String] = []
        let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: sync.seam) { [fake = fake()] argv, timeout in
            if argv.first == "/usr/bin/git" { gitSteps.append(argv[1] == "-C" ? argv[3] : argv[1]) }
            return fake(argv, timeout)
        }
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(gitSteps, ["init", "fetch", "update-ref", "read-tree"])
        XCTAssertEqual(sync.verbs, ["list", "create \(treeName)", "create \(m2Name)", "flush \(treeName)", "list"])
        XCTAssertEqual(sync.timeouts, [30, 60, 60, 240, 30])
        XCTAssertEqual(sync.m2ParentExistedAtCreate, true)
        XCTAssertEqual(sync.m2RootExistedAtCreate, false)
        XCTAssertEqual(try mode(clone.appendingPathComponent("a.txt")) & 0o222, 0)
        XCTAssertNotEqual(try mode(clone.appendingPathComponent(".git/config")) & 0o200, 0)
        XCTAssertNotEqual(try mode(clone.appendingPathComponent(".idea/ws.xml")) & 0o200, 0)
    }

    func testARefreshWhoseListHoldsBothSessionsOnlyFlushes() {
        let sync = FakeSync(lists: [both(), both()])
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: sync.seam, execute: fake()).get())
        XCTAssertEqual(sync.verbs, ["list", "flush \(treeName)", "list"])
    }

    func testAPausedTreeIsResumedAndAHaltedOneCreatedAgain() {
        let paused = FakeSync(lists: [both(tree: listed(treeName, paused: true)), both()])
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: paused.seam, execute: fake()).get())
        XCTAssertEqual(paused.verbs, ["list", "resume \(treeName)", "flush \(treeName)", "list"])
        let halted = FakeSync(lists: [both(tree: listed(treeName, status: "halted-on-root-emptied")), both()])
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: halted.seam, execute: fake()).get())
        XCTAssertEqual(halted.verbs, ["list", "terminate \(treeName)", "create \(treeName)", "flush \(treeName)", "list"])
    }

    func testSyncFailuresFailTheRefreshWithMutagensReasonButAnM2CreateOnlyLogs() {
        func message(_ sync: FakeSync) -> String? {
            if case .failure(let failure) = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: sync.seam,
                                                                     execute: fake()) { return failure.message }
            return nil
        }
        XCTAssertEqual(message(FakeSync(lists: [], failing: ["list": "daemon gone"])), "syncing p4linux:/home/s/repo failed: daemon gone")
        XCTAssertTrue(message(FakeSync(lists: ["not json"]))?.hasPrefix("syncing p4linux:/home/s/repo failed: unreadable") == true)
        XCTAssertEqual(message(FakeSync(lists: ["[]"], failing: ["create \(treeName)": "bad url"])),
                       "syncing p4linux:/home/s/repo failed: bad url")
        XCTAssertEqual(message(FakeSync(lists: [both(tree: listed(treeName, paused: true))], failing: ["resume \(treeName)": "no"])),
                       "syncing p4linux:/home/s/repo failed: no")
        XCTAssertEqual(message(FakeSync(lists: [both(), both()], failing: ["flush \(treeName)": "flush broke"])),
                       "syncing p4linux:/home/s/repo failed: flush broke")
        XCTAssertNil(message(FakeSync(lists: ["[\(listed(treeName))]", both()], failing: ["create \(m2Name)": "no m2"])))
    }

    func testAFlushTimeoutWhileTheFirstCopyRunsAsksToOpenAgain() {
        let copying = both(tree: listed(treeName, status: "staging-beta", files: (900, 0)))
        for _ in 0..<2 {
            let sync = FakeSync(lists: [both(), copying], failing: ["flush \(treeName)": "no answer within 240 s"])
            let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: sync.seam, execute: fake())
            XCTAssertEqual(result, .failure(.init(message: "first sync of p4linux:/home/s/repo is still copying; open again")))
        }
    }

    func testABusyStatusAfterAGoodFlushIsTheHostWritingAgain() {
        let busy = FakeSync(lists: [both(), both(tree: listed(treeName, status: "scanning", files: (3, 3)))])
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: busy.seam, execute: fake()).get())
        let empty = FakeSync(lists: [both(), both(tree: listed(treeName, files: (3, 0)))])
        XCTAssertEqual(RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: empty.seam, execute: fake()),
                       .failure(.init(message: "syncing p4linux:/home/s/repo failed: no files arrived from p4linux:/home/s/repo")))
    }

    func testARootProblemFailsTheRefreshWhileAPerFileProblemOnlyLogs() {
        let root = #", "transitionProblems": [{"path": "", "error": "unable to open synchronization root parent directory"}]"#
        let broken = FakeSync(lists: [both(), both(tree: listed(treeName, files: (3, 0), problems: root))])
        XCTAssertEqual(RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: broken.seam, execute: fake()),
                       .failure(.init(message: "syncing p4linux:/home/s/repo failed: unable to open synchronization root parent directory")))
        let perFile = #", "transitionProblems": [{"path": "Readme", "error": "file exists"}]"#
        let partial = FakeSync(lists: [both(), both(tree: listed(treeName, files: (3, 2), problems: perFile))])
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: partial.seam, execute: fake()).get())
    }

    func testAnM2ConflictIsDeletedSoTheHostsCopyArrives() throws {
        let jar = m2.appendingPathComponent("org/c/c.jar"), outside = m2.deletingLastPathComponent().appendingPathComponent("x")
        let elsewhere = stateDirectory.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: m2.appendingPathComponent("linked"), withDestinationURL: elsewhere)
        try "mac".write(to: jar, atomically: true, encoding: .utf8)
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        try "keep".write(to: elsewhere.appendingPathComponent("y"), atomically: true, encoding: .utf8)
        let roots = ["org/c/c.jar", "../x", ".", "/etc/hosts", "linked/y"]
        let after = "[\(listed(treeName)), \(listed(m2Name, kind: "m2", conflicts: roots))]"
        let sync = FakeSync(lists: [both(), after])
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, sync: sync.seam, execute: fake()).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: jar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: m2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("y").path))
    }

    func testTheSyncedGitStepsRunOverAWorkingTreeThatDiffersFromTheIndex() throws {
        let source = stateDirectory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func git(_ args: String..., in directory: URL) throws {
            let outcome = RebasedMirrorRefresh.runProcess(["/usr/bin/git", "-C", directory.path, "-c", "user.email=a@b", "-c", "user.name=a"] + args,
                                                          timeout: 30)
            XCTAssertEqual(outcome.status, 0, outcome.reason)
        }
        try git("init", "-q", in: source)
        try "1\n".write(to: source.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try git("add", "f", in: source)
        try git("commit", "-qm", "one", in: source)
        let localTop = source.path
        let local = try XCTUnwrap(RebasedMirror(host: "p4linux", path: localTop))
        let execute: ([String], TimeInterval) -> RebasedMirrorRefresh.Outcome = { argv, timeout in
            if argv.first == "/usr/bin/ssh" { return .init(status: 0, stdout: localTop + "\n", reason: "") }
            return RebasedMirrorRefresh.runProcess(argv.map { $0 == "p4linux:\(localTop)" ? "file://\(localTop)" : $0 }, timeout: timeout)
        }
        let localClone = local.directory(top: localTop, stateDirectory: stateDirectory)
        let localTree = RebasedMirrorSync.treeName(state: state, host: "p4linux", top: localTop)
        let list = "[\(listed(localTree)), \(listed(m2Name, kind: "m2"))]"
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(local, stateDirectory: stateDirectory,
                                                      sync: FakeSync(lists: [list, list]).seam, execute: execute).get())
        try "dirty\n".write(to: localClone.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try "2\n".write(to: source.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try git("commit", "-qam", "two", in: source)
        XCTAssertNoThrow(try RebasedMirrorRefresh.run(local, stateDirectory: stateDirectory,
                                                      sync: FakeSync(lists: [list, list]).seam, execute: execute).get())
        let status = RebasedMirrorRefresh.runProcess(["/usr/bin/git", "-C", localClone.path, "status", "--short"], timeout: 30)
        XCTAssertEqual(status.stdout, " M f\n")
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
}

/// Answers each `mutagen sync list` with the next of `lists`; a call whose verb (`create <name>`) is in `failing` fails.
final class FakeSync: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [String]
    private let failing: [String: String]
    private var calls: [(verb: String, timeout: TimeInterval)] = []
    private(set) var m2ParentExistedAtCreate: Bool?
    private(set) var m2RootExistedAtCreate: Bool?

    init(lists: [String], failing: [String: String] = [:]) {
        self.lists = lists
        self.failing = failing
    }

    var verbs: [String] { lock.withLock { calls.map(\.verb) } }
    var timeouts: [TimeInterval] { lock.withLock { calls.map(\.timeout) } }

    var seam: RebasedMirrorRefresh.Sync {
        RebasedMirrorRefresh.Sync(binary: { "/fake/mutagen" }, run: { [self] argv, timeout in answer(argv, timeout) })
    }

    private func answer(_ argv: [String], _ timeout: TimeInterval) -> RebasedMirrorRefresh.Outcome {
        lock.withLock {
            let verb = argv[2] == "list" ? "list" : "\(argv[2]) \(argv[argv[2] == "create" ? 5 : 3])"
            calls.append((verb, timeout))
            if argv.contains("agterm-kind=m2") {
                let root = URL(fileURLWithPath: argv[argv.count - 1])
                m2RootExistedAtCreate = FileManager.default.fileExists(atPath: root.path)
                m2ParentExistedAtCreate = FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path)
            }
            if let reason = failing[verb] { return .init(status: 1, stdout: "", reason: reason) }
            if verb == "list" { return .init(status: 0, stdout: lists.isEmpty ? "[]" : lists.removeFirst(), reason: "") }
            return .init(status: 0, stdout: "", reason: "")
        }
    }
}
