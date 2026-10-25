import AppKit
import XCTest
@testable import agterm
import agtermCore

extension RebasedHost {
    /// A host that touches no live state: fake runtime and frames, a scratch state directory, mirror jobs run inline.
    /// A bare `RebasedHost()` keeps the live state directory and the real runtime.
    static func isolated(stateDirectory: URL, store: AppStore, runtime: FakeRebasedRuntime = FakeRebasedRuntime(),
                         frames: FakeRebasedFrames = FakeRebasedFrames()) -> RebasedHost {
        let host = RebasedHost()
        host.runtime = runtime
        host.frames = frames
        host.store = { [weak store] _ in store }
        host.after = { _, _ in }
        host.offMain = { work, done in
            work()
            done()
        }
        host.onMirrorQueue = { work, done in
            work()
            done()
        }
        host.stateDirectory = stateDirectory
        host.mirrorRefresh = { _, _, _ in .failure(.init(message: "no refresh in this test")) }
        host.install()
        return host
    }
}

@MainActor
final class RebasedHostSyncTests: XCTestCase {
    private var directory: URL!
    private var store: AppStore!
    private var host: RebasedHost!
    private var runtime: FakeRebasedRuntime!
    private var remote: Session!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("rebased-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AppStore(persistence: PersistenceStore(directory: directory))
        runtime = FakeRebasedRuntime()
        host = RebasedHost.isolated(stateDirectory: directory, store: store, runtime: runtime)
        let workspace = store.addWorkspace(name: "remote")
        remote = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "p4linux"))
    }

    override func tearDown() async throws {
        RebasedOverlayReleases.shared.onRelease = nil
        RebasedOverlayReleases.shared.onHiddenChange = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheRefreshGetsTheHostsSyncSeam() throws {
        let binaries = Recorder<String?>()
        host.sync = RebasedMirrorRefresh.Sync(binary: { "/seam/mutagen" }, run: { _, _ in .init(status: 0, stdout: "[]", reason: "") })
        host.mirrorRefresh = { _, _, sync in
            binaries.append(sync.binary())
            return .failure(.init(message: "offline"))
        }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        XCTAssertEqual(binaries.items, ["/seam/mutagen"])
    }

    func testOpeningAgainAfterTheFirstCopyRefusalStartsTheIDE() throws {
        let copying = "first sync of p4linux:/home/s/repo is still copying; open again"
        host.mirrorRefresh = { _, _, _ in .failure(.init(message: copying)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        XCTAssertEqual(remote.rebasedOverlay?.state, .failed(copying))
        let id = remote.rebasedOverlay?.id

        host.mirrorRefresh = { _, _, _ in .success(.init(directory: "/tmp", source: "p4linux:/home/s/repo")) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        XCTAssertEqual(remote.rebasedOverlay?.id, id)
        XCTAssertEqual(remote.rebasedOverlay?.project, "/tmp")
        XCTAssertEqual(remote.rebasedOverlay?.state, .starting)
        XCTAssertEqual(host.jvm, .starting)
    }

    // MARK: Prune and sweep

    private var state: String { RebasedMirrorSync.stateID(stateDirectory: directory) }

    /// A mirror of `host:/home/s/<name>` last opened 30 days ago; its tree session's JSON, as `sync list` gives it.
    private func staleMirror(host: String = "p4linux", name: String = "repo") throws -> (clone: URL, session: String) {
        let top = "/home/s/\(name)"
        let clone = try XCTUnwrap(RebasedMirror(host: host, path: top)).directory(top: top, stateDirectory: directory)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try RebasedMirrorMarker(source: "\(host):\(top)", lastOpened: Date().addingTimeInterval(-30 * 86_400))
            .write(to: clone.deletingLastPathComponent())
        let name = RebasedMirrorSync.treeName(state: state, host: host, top: top)
        return (clone, Self.session(name, kind: "tree", beta: clone.path))
    }

    private static func session(_ name: String, kind: String, beta: String) -> String {
        #"{"name": "\#(name)", "labels": {"agterm-kind": "\#(kind)"}, "status": "watching", "alpha": {"path": "a"}, "beta": {"path": "\#(beta)"}}"#
    }

    private func m2Session(host: String = "p4linux") -> String {
        Self.session(RebasedMirrorSync.m2Name(state: state, host: host), kind: "m2",
                     beta: RebasedMirrorSync.m2Directory(host: host, stateDirectory: directory).path)
    }

    private func prune(_ sync: RebasedMirrorRefresh.Sync) throws -> RebasedMirrorCleanup.Report {
        let prune = RebasedHost.makeMirrorPrune(withLock: { _, body in try body() }, sync: sync)
        return try prune(.init(stateDirectory: directory, inUse: [], maxAgeDays: 7, dryRun: false))
    }

    func testAPruneEndsTheListedTreeSessionBeforeTheCloneGoes() throws {
        let (clone, tree) = try staleMirror()
        let (otherClone, _) = try staleMirror(name: "other")
        let sync = FakeSync(lists: ["[\(tree)]"])
        let report = try prune(sync.seam)
        XCTAssertEqual(sync.verbs, ["list", "terminate \(RebasedMirrorSync.treeName(state: state, host: "p4linux", top: "/home/s/repo"))"])
        XCTAssertEqual(report.removed.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherClone.path))
    }

    func testWithNoBinaryOrNoStaleMirrorThePruneCallsNoMutagen() throws {
        let (clone, _) = try staleMirror()
        XCTAssertEqual(try prune(.none).removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path))
        let sync = FakeSync(lists: [])
        XCTAssertEqual(try prune(sync.seam).removed.count, 0)
        XCTAssertEqual(sync.verbs, [])
    }

    func testAFailedTerminateOrListKeepsTheMirror() throws {
        let (clone, tree) = try staleMirror()
        let name = RebasedMirrorSync.treeName(state: state, host: "p4linux", top: "/home/s/repo")
        let refused = try prune(FakeSync(lists: ["[\(tree)]"], failing: ["terminate \(name)": "daemon busy"]).seam)
        XCTAssertEqual(refused.kept.first?.error, "mutagen sync terminate \(name): daemon busy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path))
        let (otherClone, _) = try staleMirror(name: "other")
        let unlisted = try prune(FakeSync(lists: [], failing: ["list": "no daemon"]).seam)
        XCTAssertEqual(Set(unlisted.kept.map(\.error)), ["mutagen sync list: no daemon"])
        XCTAssertEqual(unlisted.kept.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherClone.path))
    }

    func testTheHostsLastMirrorEndsItsM2SessionAndKeepsTheCopy() throws {
        let (_, tree) = try staleMirror()
        let copy = RebasedMirrorSync.m2Directory(host: "p4linux", stateDirectory: directory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let sync = FakeSync(lists: ["[\(tree), \(m2Session())]"])
        _ = try prune(sync.seam)
        XCTAssertEqual(sync.verbs.last, "terminate \(RebasedMirrorSync.m2Name(state: state, host: "p4linux"))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        let failing = FakeSync(lists: ["[\(try staleMirror().session), \(m2Session())]"],
                               failing: ["terminate \(RebasedMirrorSync.m2Name(state: state, host: "p4linux"))": "busy"])
        XCTAssertEqual(try prune(failing.seam).removed.count, 1)
    }

    func testTheSweepEndsSessionsWhoseMirrorIsGoneAndKeepsEveryCopy() throws {
        let (kept, keptTree) = try staleMirror()
        let gone = directory.appendingPathComponent("rebased/mirrors/p4linux/feed/gone")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let goneTree = Self.session("agterm-\(state)-x-gone", kind: "tree", beta: gone.path)
        let orphanCopy = RebasedMirrorSync.m2Directory(host: "p4air", stateDirectory: directory)
        try FileManager.default.createDirectory(at: orphanCopy, withIntermediateDirectories: true)
        let sync = FakeSync(lists: ["[\(keptTree), \(goneTree), \(m2Session()), \(m2Session(host: "p4air"))]"])
        RebasedHost.sweepSessions(stateDirectory: directory, sync: sync.seam)
        XCTAssertEqual(sync.verbs, ["list", "terminate agterm-\(state)-x-gone",
                                    "terminate \(RebasedMirrorSync.m2Name(state: state, host: "p4air"))"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanCopy.path))
        RebasedHost.sweepSessions(stateDirectory: directory, sync: .none)
    }

    func testTheSweepIsQueuedOnceAtTheFirstStartWithoutHoldingTheLaunch() throws {
        let sync = FakeSync(lists: [])
        host.sync = sync.seam
        var jobs = 0
        host.onMirrorQueue = { work, done in
            jobs += 1
            work()
            done()
        }
        let local = try XCTUnwrap(store.addSession(toWorkspace: store.addWorkspace(name: "local").id, cwd: "/tmp"))
        XCTAssertNil(store.openRebasedOverlay(local.id, overlay: RebasedOverlay(project: "/tmp"), sizePercent: nil))
        host.open(session: local.id)
        XCTAssertEqual(runtime.starts, 1)
        XCTAssertEqual(sync.verbs, ["list"])
        XCTAssertEqual(jobs, 1)
        host.enqueueSweep()
        XCTAssertEqual(jobs, 1)
    }

    func testARetryWithoutOnCloseKeepsTheFirstCallbackArmed() throws {
        var commands: [RebasedOnClose] = []
        host.runOnClose = { commands.append($0) }
        let copying = "first sync of p4linux:/home/s/repo is still copying; open again"
        host.mirrorRefresh = { _, _, _ in .failure(.init(message: copying)) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil,
                                              onClose: "flush --final").get())
        XCTAssertEqual(remote.rebasedOverlay?.state, .failed(copying))
        host.mirrorRefresh = { _, _, _ in .success(.init(directory: "/tmp", source: "p4linux:/home/s/repo")) }
        XCTAssertNoThrow(try host.openOverlay(in: store, session: remote.id, cwd: "/home/s/repo", sizePercent: nil).get())
        XCTAssertEqual(remote.rebasedOverlay?.state, .starting)
        XCTAssertEqual(remote.rebasedOverlay?.onClose?.host, "p4linux")
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(store.closeRebasedOverlay(remote.id, id: try XCTUnwrap(remote.rebasedOverlay?.id)))
        XCTAssertEqual(commands.map(\.command), ["flush --final"])
    }
}
