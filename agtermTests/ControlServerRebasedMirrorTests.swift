import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRebasedMirrorTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var previousHost: RebasedHost!

    override func setUp() async throws {
        stateDir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agterm-rebased-mirrors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        library = WindowLibrary(directory: stateDir)
        server = makeServer()
        previousHost = RebasedHost.shared
        let host = RebasedHost()
        host.runtime = FakeRebasedRuntime()
        host.frames = FakeRebasedFrames()
        host.store = { [library] in library?.store(forSession: $0) }
        host.after = { _, _ in }
        host.offMain = { work, done in
            work()
            done()
        }
        host.onMirrorQueue = { work, done in
            work()
            done()
        }
        host.stateDirectory = stateDir
        host.mirrorPrune = { RebasedMirrorCleanup.prune($0) }
        host.mirrorList = { RebasedMirrorCleanup.scan(stateDirectory: $0, inUse: $1, measure: true) }
        host.install()
        RebasedHost.shared = host
    }

    override func tearDown() async throws {
        RebasedHost.shared = previousHost
        RebasedOverlayReleases.shared.onRelease = nil
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func makeServer() -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                      socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    @discardableResult
    private func seedMirror(host: String, hash: String, name: String, ageDays: Double) throws -> URL {
        let hashDirectory = stateDir.appendingPathComponent("rebased/mirrors/\(host)/\(hash)", isDirectory: true)
        let clone = hashDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let opened = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - ageDays * 86_400).rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: opened], ofItemAtPath: hashDirectory.path)
        return clone
    }

    private func mirrors(_ cmd: Command, _ args: ControlArgs? = nil) async throws -> ControlRebasedMirrors {
        let response = await server.dispatch(ControlRequest(cmd: cmd, args: args))
        XCTAssertTrue(response.ok, response.error ?? "")
        return try XCTUnwrap(response.result?.rebasedMirrors)
    }

    func testListShowsEveryMirrorAndMarksTheOneAnOverlayHolds() async throws {
        let held = try seedMirror(host: "p4linux", hash: "0a1b2c3d", name: "jackrabbit", ageDays: 1)
        let other = try seedMirror(host: "p4air", hash: "4e5f6a7b", name: "oak", ageDays: 20)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: held.path))
        XCTAssertNil(RebasedHost.shared.openOverlay(in: store, session: session.id, cwd: nil, sizePercent: nil))

        let answer = try await mirrors(.rebasedMirrorList)

        let nodes = try XCTUnwrap(answer.mirrors)
        XCTAssertEqual(Set(nodes.map(\.directory)), [held.path, other.path])
        XCTAssertEqual(nodes.first { $0.directory == held.path }?.inUse, true)
        XCTAssertEqual(nodes.first { $0.directory == other.path }?.inUse, false)
        XCTAssertNotNil(nodes.first?.bytes)
    }

    func testADryRunRemovesNothingAndAPruneRemovesOnlyTheStaleMirror() async throws {
        let stale = try seedMirror(host: "p4air", hash: "4e5f6a7b", name: "oak", ageDays: 20)
        let fresh = try seedMirror(host: "p4linux", hash: "0a1b2c3d", name: "jackrabbit", ageDays: 1)
        let staleHost = stateDir.appendingPathComponent("rebased/mirrors/p4air")

        let dryRun = try await mirrors(.rebasedMirrorPrune, ControlArgs(olderThanDays: 7, dryRun: true))
        XCTAssertEqual(dryRun.removed?.map(\.directory), [stale.path])
        XCTAssertEqual(dryRun.dryRun, true)
        XCTAssertEqual(dryRun.olderThanDays, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleHost.path))

        let prune = try await mirrors(.rebasedMirrorPrune, ControlArgs(olderThanDays: 7))
        XCTAssertEqual(prune.removed?.map(\.directory), [stale.path])
        XCTAssertEqual(prune.dryRun, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testAPruneWithoutAnAgeUsesTheSetting() async throws {
        let answer = try await mirrors(.rebasedMirrorPrune, ControlArgs(dryRun: true))
        XCTAssertEqual(answer.olderThanDays, 14)
    }

    func testAPruneWithoutAnAgeIsRefusedWhenTheSettingIsZero() async throws {
        try SettingsStore(directory: stateDir).save(AppSettings(rebasedMirrorMaxAgeDays: 0))
        server = makeServer()
        let stale = try seedMirror(host: "p4air", hash: "4e5f6a7b", name: "oak", ageDays: 20)

        let response = await server.dispatch(ControlRequest(cmd: .rebasedMirrorPrune))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "automatic mirror pruning is off (rebasedMirrorMaxAgeDays is 0); pass --older-than DAYS")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    }

    func testBothMirrorCommandsLeaveTheAcceptThread() {
        XCTAssertTrue(ControlServer.waitsOnNetwork(.rebasedMirrorList))
        XCTAssertTrue(ControlServer.waitsOnNetwork(.rebasedMirrorPrune))
    }
}
