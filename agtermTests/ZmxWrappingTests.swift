import agtermCore
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

    private func command(_ wrapping: ZmxWrapping, role: ZmxSessionKey.Role = .left,
                         pinnedCommand: String? = nil, keepShellOpen: Bool = false) -> String? {
        wrapping.command(sessionID: sessionID, role: role, pinnedCommand: pinnedCommand,
                         keepShellOpen: keepShellOpen)
    }

    // MARK: - what the factories get back

    func testPlainRowIsWrappedUnderItsLeftKey() {
        XCTAssertEqual(command(wrapping()), "'\(zmx)' 'attach' '\(leftKey)'")
    }

    func testSplitPaneIsWrappedUnderTheRightKey() {
        XCTAssertEqual(command(wrapping(), role: .right),
                       "'\(zmx)' 'attach' '\(sessionID.uuidString)-right'")
    }

    func testPinnedCommandRowIsLeftAlone() {
        XCTAssertNil(command(wrapping(), pinnedCommand: "ssh host"))
    }

    func testKeepShellOpenRunsTheCommandInsideZmxShell() {
        let line = command(wrapping(), pinnedCommand: "claude", keepShellOpen: true)
        XCTAssertEqual(line, "'\(zmx)' 'attach' '\(leftKey)' '/bin/zsh' '-lc' 'claude; exec '\\''/bin/zsh'\\'' '\\''-l'\\'''")
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

    /// The budget probe must be fed `ZmxSessionKey.maxByteCount`, not the 42 bytes a `left`/`right` key
    /// really takes: this directory is 57 bytes, which fits at 42 and overruns at 44.
    func testBudgetProbeUsesTheWorstCaseKeyLength() {
        let dir = "/tmp/" + String(repeating: "z", count: 52)
        XCTAssertEqual(dir.utf8.count, 57)
        XCTAssertNil(command(wrapping(env: ["SHELL": "/bin/zsh", "ZMX_DIR": dir])))
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

    func testCaptureAbandonsAnOverrunningCall() {
        let started = Date()
        XCTAssertNil(ZmxClient.capture("/bin/sh", ["-c", "sleep 20"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testNoopClientAnswersNothing() {
        XCTAssertNil(ZmxClient.noop.locate())
        XCTAssertNil(ZmxClient.noop.list())
        ZmxClient.noop.setLabel("key", "name")
        ZmxClient.noop.kill("key")
    }

    // MARK: - the inherited session scrub

    func testScrubRemovesAnInheritedSession() {
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
