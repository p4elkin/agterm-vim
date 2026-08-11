import agtermCore
import os
import XCTest
@testable import agterm

/// The app-side zmx seam: assembling `ZmxWrap.Inputs` from an environment and a located binary, finding the
/// binary, and the bounded subprocess call. The decision itself is host-free (`ZmxWrapTests`); what this
/// pins is what the surface factories feed it.
final class ZmxWrappingTests: XCTestCase {
    private let sessionID = UUID(uuidString: "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F")!
    private let zmx = "/opt/homebrew/bin/zmx"
    private var leftKey: String { "\(sessionID.uuidString)-left" }

    private func wrapping(env: [String: String] = ["SHELL": "/bin/zsh"],
                          zmxPath: String? = "/opt/homebrew/bin/zmx") -> ZmxWrapping {
        var client = ZmxClient.noop
        client.locate = { zmxPath }
        return ZmxWrapping(env: env, client: client)
    }

    private func command(_ wrapping: ZmxWrapping, role: ZmxSessionKey.Role = .left, existingKey: String? = nil,
                         siblingKey: String? = nil, pinnedCommand: String? = nil,
                         keepShellOpen: Bool = false) -> String? {
        wrapping.command(sessionID: sessionID, role: role, keys: (existingKey, siblingKey),
                         pinnedCommand: pinnedCommand, keepShellOpen: keepShellOpen)?.command
    }

    // MARK: - what the factories get back

    func testPlainRowIsWrappedUnderItsLeftKey() {
        XCTAssertEqual(command(wrapping()), "'\(zmx)' 'attach' '\(leftKey)'")
    }

    func testSplitPaneIsWrappedUnderTheRightKey() {
        XCTAssertEqual(command(wrapping(), role: .right),
                       "'\(zmx)' 'attach' '\(sessionID.uuidString)-right'")
    }

    /// The factories record `key` on the session and hand it back here on the next launch, so a promoted
    /// survivor re-attaches to the `-right` daemon holding its agent rather than a fresh `-left` one.
    func testTheReportedKeyIsWhatTheFactoryMustRecord() {
        let wrapped = wrapping().command(sessionID: sessionID, role: .left, keys: (nil, nil),
                                         pinnedCommand: nil, keepShellOpen: false)
        XCTAssertEqual(wrapped?.key, leftKey)
        XCTAssertTrue(wrapped?.command.contains(leftKey) == true)
        let promoted = "\(sessionID.uuidString)-right"
        let readBack = wrapping().command(sessionID: sessionID, role: .left, keys: (promoted, nil),
                                          pinnedCommand: nil, keepShellOpen: false)
        XCTAssertEqual(readBack?.key, promoted)
        XCTAssertEqual(readBack?.command, "'\(zmx)' 'attach' '\(promoted)'")
    }

    /// ⚠️ The sibling's key has to reach the decision through this seam too, or a Command-D after a
    /// promotion hands the new split the daemon the main pane is already a client of.
    func testAPaneIsNotWrappedUnderTheKeyItsSiblingOwns() {
        XCTAssertNil(command(wrapping(), role: .right, siblingKey: "\(sessionID.uuidString)-right"))
        XCTAssertNotNil(command(wrapping(), role: .right, siblingKey: leftKey))
    }

    func testPinnedCommandRowIsLeftAlone() {
        XCTAssertNil(command(wrapping(), pinnedCommand: "ssh host"))
    }

    func testKeepShellOpenRunsTheCommandInsideZmxShell() {
        let line = command(wrapping(), pinnedCommand: "claude", keepShellOpen: true)
        XCTAssertEqual(line, "'\(zmx)' 'attach' '\(leftKey)' '/bin/zsh' '-lc' 'claude\nexec '\\''/bin/zsh'\\'' '\\''-l'\\'''")
    }

    /// ⚠️ The claim the whole flag exists for, RUN rather than spelled: the row must land at a prompt after
    /// its command exits. The stub stands in for `zmx attach <key>`, which drops those two arguments and runs
    /// the rest, so the assertion covers the real line including every level of quoting.
    func testTheKeepShellOpenWrapperLeavesAShellRunningAfterTheCommand() throws {
        let stub = try makeTemporaryDirectory().appendingPathComponent("zmx")
        try "#!/bin/sh\nshift 2\nexec \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let wrapper = try XCTUnwrap(command(wrapping(env: ["SHELL": "/bin/sh"], zmxPath: stub.path),
                                            pinnedCommand: "echo ran-the-command", keepShellOpen: true))

        let output = ZmxClient.capture("/bin/sh", ["-c", "printf 'echo survived\\n' | \(wrapper)"], timeout: 10)

        XCTAssertEqual(output?.contains("ran-the-command"), true, "\(output ?? "no output")")
        XCTAssertEqual(output?.contains("survived"), true, "the shell did not outlive the command")
    }

    /// The fallback is the FULL path, because the wrapper `exec`s it inside its own script.
    func testMissingShellFallsBackToTheZshPath() {
        for env in [[String: String](), ["SHELL": ""]] {
            let line = command(wrapping(env: env), pinnedCommand: "claude", keepShellOpen: true) ?? ""
            XCTAssertTrue(line.contains("'/bin/zsh' '-lc'"), line)
            XCTAssertFalse(line.contains("'zsh' '-lc'"), line)
        }
    }

    func testIsolatedStateDirectoryWrapsNothing() {
        let isolated = wrapping(env: ["SHELL": "/bin/zsh", "AGTERM_STATE_DIR": "/tmp/agterm-test"])
        XCTAssertNil(command(isolated))
        XCTAssertNil(command(isolated, pinnedCommand: "claude", keepShellOpen: true))
    }

    func testMissingBinaryWrapsNothing() {
        XCTAssertNil(command(wrapping(zmxPath: nil)))
    }

    func testOverBudgetSocketPathWrapsNothing() {
        let long = "/tmp/" + String(repeating: "z", count: 120)
        XCTAssertNil(command(wrapping(env: ["SHELL": "/bin/zsh", "ZMX_DIR": long])))
    }

    /// The probe is fed the key length rather than a number written down beside it: at 42 bytes plus a
    /// separator the budget breaks between a 58-byte and a 59-byte directory, and the pane must wrap on the
    /// low side of that line and not on the high side.
    func testBudgetIsMeasuredWithTheRealKeyLength() {
        func directory(bytes: Int) -> String { "/tmp/" + String(repeating: "z", count: bytes - 5) }
        let fits = directory(bytes: ZmxSocketBudget.maxPathByteCount - 1 - ZmxSessionKey.maxByteCount)
        XCTAssertEqual(fits.utf8.count, 58)
        XCTAssertNotNil(command(wrapping(env: ["SHELL": "/bin/zsh", "ZMX_DIR": fits])))
        XCTAssertNil(command(wrapping(env: ["SHELL": "/bin/zsh", "ZMX_DIR": directory(bytes: 59)])))
    }

    // MARK: - locating the binary

    func testLocateBinaryFindsAnExecutableOnPath() throws {
        let dir = try makeTemporaryDirectory()
        let candidate = dir.appendingPathComponent("zmx")
        try Data().write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        XCTAssertEqual(ZmxClient.locateBinary(env: ["PATH": dir.path]), candidate.path)
    }

    func testLocateBinarySkipsANonExecutableFile() throws {
        let dir = try makeTemporaryDirectory()
        let candidate = dir.appendingPathComponent("zmx")
        try Data().write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidate.path)
        XCTAssertNotEqual(ZmxClient.locateBinary(env: ["PATH": dir.path]), candidate.path)
    }

    // MARK: - the bounded subprocess call

    func testCaptureReturnsStdout() {
        XCTAssertEqual(ZmxClient.capture("/bin/echo", ["hello"]), "hello\n")
    }

    func testCaptureReturnsNilForANonZeroExit() {
        XCTAssertNil(ZmxClient.capture("/bin/sh", ["-c", "exit 3"]))
    }

    func testCaptureReturnsNilForAMissingExecutable() {
        XCTAssertNil(ZmxClient.capture("/nonexistent/zmx", ["list"]))
    }

    /// Bounded by a small multiple of the CONFIGURED timeout: a five-second bound passes a timeout broken by
    /// an order of magnitude.
    func testCaptureAbandonsAnOverrunningCall() {
        let started = Date()
        XCTAssertNil(ZmxClient.capture("/bin/sh", ["-c", "sleep 20"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    /// Output larger than the 64 KB pipe buffer: draining stdout on the CALLING thread deadlocks here, and
    /// `zmx list` on a busy machine is what would hit it in production.
    func testCaptureDrainsMoreThanOnePipeBuffer() {
        let output = ZmxClient.capture("/bin/sh", ["-c", "yes agterm | head -c 200000"], timeout: 5)
        XCTAssertEqual(output?.utf8.count, 200_000)
    }

    /// `setLabel`/`kill` return nothing and reach nothing, so there is no assertion to make about them here;
    /// that a noop client performs no effect is pinned where it matters, through the sink below.
    func testNoopClientAnswersNothing() {
        XCTAssertNil(ZmxClient.noop.locate())
        XCTAssertNil(ZmxClient.noop.list())
    }

    // MARK: - what an isolated instance may reach

    /// The reap and the close/rename sink are the two effects that can touch a daemon this instance never
    /// created, so both bypasses are driven rather than read: a deployed instance ends the unclaimed daemon
    /// and spares the claimed one, and the same call under `AGTERM_STATE_DIR` touches nothing.
    func testReapEndsOnlyAnUnclaimedDaemonAndNothingAtAllWhenIsolated() throws {
        let directory = try makeTemporaryDirectory()
        let claimed = UUID()
        let orphan = UUID()
        let session = SessionSnapshot(id: claimed, customName: nil, cwd: "/a")
        let snapshot = Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [session])])
        try PersistenceStore(directory: directory.appendingPathComponent("windows", isDirectory: true),
                             fileName: "\(UUID().uuidString).json").save(snapshot)
        let listing = [ZmxListParser.Entry(name: "\(claimed.uuidString)-left", clients: 0, leaderPID: 1),
                       ZmxListParser.Entry(name: "\(orphan.uuidString)-left", clients: 0, leaderPID: 2)]

        let killed = KillLog()
        var client = ZmxClient.noop
        client.locate = { "/opt/homebrew/bin/zmx" }
        client.list = { listing }
        client.kill = { killed.record($0) }

        ZmxWrapping(env: ["SHELL": "/bin/zsh"], client: client).reapOrphanedSessions(directory: directory)
        killed.waitForOneCall()
        XCTAssertEqual(killed.keys, ["\(orphan.uuidString)-left"])

        let isolated = ZmxWrapping(env: ["SHELL": "/bin/zsh", "AGTERM_STATE_DIR": directory.path], client: client)
        isolated.reapOrphanedSessions(directory: directory)
        killed.waitForNothingBeyond(["\(orphan.uuidString)-left"])
    }

    @MainActor
    func testTheSessionSinkOfAnIsolatedInstanceEndsAndLabelsNothing() {
        let killed = KillLog()
        var client = ZmxClient.noop
        client.kill = { killed.record($0) }
        client.setLabel = { key, _ in killed.record(key) }

        let isolated = ZmxWrapping(env: ["AGTERM_STATE_DIR": "/tmp/agterm-test"], client: client).sessionSink
        isolated.end(leftKey)
        isolated.label(leftKey, "work")
        killed.waitForNothingBeyond([])

        ZmxWrapping(env: [:], client: client).sessionSink.end(leftKey)
        killed.waitForOneCall()
        XCTAssertEqual(killed.keys, [leftKey])
    }

    /// Both effects run off the main actor, so the keys arrive on another thread. Polled rather than waited
    /// on: a semaphore here is the caller's user-interactive thread blocking on a utility one, which the
    /// thread performance checker reports as a priority inversion on every run.
    private final class KillLog: Sendable {
        private let recorded = OSAllocatedUnfairLock(initialState: [String]())

        var keys: [String] { recorded.withLock { $0 } }

        func record(_ key: String) { recorded.withLock { $0.append(key) } }

        func waitForOneCall(file: StaticString = #filePath, line: UInt = #line) {
            let deadline = Date().addingTimeInterval(2)
            while keys.isEmpty, Date() < deadline { usleep(5_000) }
            XCTAssertFalse(keys.isEmpty, "no zmx call arrived", file: file, line: line)
        }

        /// A bypassed call gets the same window to land in before it counts as never having happened.
        /// `expected` is spelled out rather than snapshotted first: a late call from the PREVIOUS step would
        /// otherwise land in the baseline and be absorbed instead of failing.
        func waitForNothingBeyond(_ expected: [String], file: StaticString = #filePath,
                                  line: UInt = #line) {
            usleep(300_000)
            XCTAssertEqual(keys, expected, "an isolated instance called zmx", file: file, line: line)
        }
    }

    // MARK: - the inherited session scrub

    func testScrubRemovesAnInheritedSession() {
        // restored even on failure: leaking ZMX_SESSION would follow every later test in this host process
        let previous = ProcessInfo.processInfo.environment[ZmxWrapping.inheritedSessionVariable]
        addTeardownBlock {
            if let previous { setenv(ZmxWrapping.inheritedSessionVariable, previous, 1) }
        }
        setenv(ZmxWrapping.inheritedSessionVariable, "\(leftKey)", 1)
        ZmxWrapping.scrubInheritedSession()
        XCTAssertNil(ProcessInfo.processInfo.environment[ZmxWrapping.inheritedSessionVariable])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zmx-wrapping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
