import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
import AgtermHeadlessKit

struct ZmxRunnerTests {
    private func runner(_ executable: String, base: [String: String] = [:]) -> ProcessZmxRunner {
        ProcessZmxRunner(executable: executable, zmxDirectory: "/tmp/zmx-runner-test", baseEnvironment: base)
    }

    @Test func aHungChildTimesOutWithinTheGrace() {
        let clock = ContinuousClock()
        let start = clock.now
        let result = runner("/bin/sleep").run(["30"], timeout: 1)

        #expect(result == .timedOut)
        #expect(clock.now - start < .seconds(2))
    }

    @Test(arguments: [("exit 0", 5.0), ("wait", 0.5)])
    func aDescendantHoldingThePipeDoesNotHoldTheCall(_ ending: String, _ timeout: TimeInterval) throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("zmx-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let clock = ContinuousClock()
        let start = clock.now
        let result = runner("/bin/sh").run(["-c", "/bin/sleep 30 & echo $! > '\(pidFile.path)'; \(ending)"], timeout: timeout)
        let elapsed = clock.now - start
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }

        #expect(result == .timedOut)
        #expect(elapsed < .seconds(timeout + 1))
        #expect(kill(pid, 0) == 0)
    }

    @Test func theChildCanBeSignalledWhateverTheCallingThreadBlocks() async {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var all = sigset_t()
                var previous = sigset_t()
                sigfillset(&all)
                precondition(pthread_sigmask(SIG_BLOCK, &all, &previous) == 0)
                let result = runner("/bin/sh").run(["-c", "kill -TERM $$; echo survived"], timeout: 5)
                pthread_sigmask(SIG_SETMASK, &previous, nil)
                continuation.resume(returning: result)
            }
        }

        #expect(result == .failed(128 + SIGTERM, ""))
    }

    @Test func aNonzeroExitIsAFailureWithStderr() {
        let result = runner("/bin/sh").run(["-c", "echo out; echo boom >&2; exit 3"], timeout: 5)

        #expect(result == .failed(3, "boom\n"))
    }

    @Test func aCleanExitReturnsStdout() {
        #expect(runner("/bin/sh").run(["-c", "echo listed"], timeout: 5) == .ok("listed\n"))
    }

    @Test func theChildSeesTheZmxDirectoryAndNoInheritedSession() {
        let base = ["ZMX_SESSION": "outer", "ZMX_SESSION_PREFIX": "p-", "KEPT": "yes"]
        let script = #"printf '%s|%s|%s|%s|%s' "$ZMX_DIR" "${ZMX_SESSION-unset}" "${ZMX_SESSION_PREFIX-unset}" "$KEPT" "$ADDED""#
        let result = runner("/bin/sh", base: base).run(["-c", script], environment: ["ADDED": "pane"], timeout: 5)

        #expect(result == .ok("/tmp/zmx-runner-test|unset|unset|yes|pane"))
    }

    @Test func inheritedRoutingIsRemovedBeforeTheOwnedEnvironmentIsAdded() throws {
        let polluted = [
            "AGTERM_SESSION_ID": "viewer-session", "AGTERM_SOCKET": "/tmp/viewer.sock",
            "AGTERM_STATE_DIR": "/tmp/viewer-state", "AGTERM_PANE_ID": "viewer-pane",
            "AGTERM_WINDOW_ID": "viewer-window", "AGTERM_WORKSPACE_ID": "viewer-workspace",
            "AGTERM_PANE": "right", "AGTERM_ENABLED": "0", "AGTERMCTL": "/tmp/viewer-cli",
            "AGTERM_REMOTE_HOST": "viewer", "AGTERM_CTL_REMOTE_HOST": "viewer",
            "AGTERM_REMOTE_SELF_HOST": "origin", "AGTERM_PAGE_HOST": "viewer",
            "AGTERM_FUTURE_ROUTING_KEY": "stale", "KEPT": "yes",
        ]
        let owned = ["AGTERM_SESSION_ID": "new-session", "AGTERM_SOCKET": "/tmp/origin.sock", "AGTERM_ENABLED": "1"]
        let result = runner("/usr/bin/env", base: polluted).run([], environment: owned, timeout: 5)
        guard case .ok(let output) = result else {
            Issue.record("\(result)")
            return
        }
        let environment = Dictionary(uniqueKeysWithValues: output.split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), String(parts[1]))
        })

        for key in polluted.keys where key != "KEPT" { #expect(environment[key] == owned[key]) }
        #expect(environment["KEPT"] == "yes")
        #expect(environment["ZMX_DIR"] == "/tmp/zmx-runner-test")
    }

    @Test func theWorkingDirectoryIsApplied() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zmx-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = runner("/bin/sh").run(["-c", "pwd -P"], workingDirectory: directory.path, timeout: 5)

        guard case .ok(let output) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(output.hasSuffix(directory.lastPathComponent + "\n"))
    }

    @Test func aMissingExecutableIsALaunchFailure() {
        guard case .launchFailed = runner("/nonexistent/zmx").run(["list"], timeout: 5) else {
            Issue.record("expected a launch failure")
            return
        }
    }

    @MainActor @Test func theSynchronousCoreReturnsOnTheMainActor() {
        #expect(runner("/bin/sh").run(["-c", "exit 0"], timeout: 5) == .ok(""))
    }

    @Test func theBackgroundEntryRunsTheSameCore() async {
        #expect(await runner("/bin/sh").runInBackground(["-c", "echo async"], timeout: 5) == .ok("async\n"))
    }

    @Test func inputReachesTheChildFollowedByEndOfInput() {
        let input = "typed\rcafé\u{1b}[A\n"

        #expect(runner("/bin/cat").run([], input: Data(input.utf8), timeout: 5) == .ok(input))
    }

    @Test func noInputIsAnEmptyStdin() {
        #expect(runner("/bin/cat").run([], timeout: 5) == .ok(""))
    }

    @Test func aChildThatNeverReadsItsInputNeitherHangsNorKillsTheCaller() {
        let clock = ContinuousClock()
        let start = clock.now
        let result = runner("/bin/sh").run(["-c", "exit 0"], input: Data(count: 1 << 20), timeout: 5)

        #expect(result == .ok(""))
        #expect(clock.now - start < .seconds(2))
    }

    @Test func theBackgroundEntryPassesInput() async {
        #expect(await runner("/bin/cat").runInBackground([], input: Data("bg".utf8), timeout: 5) == .ok("bg"))
    }
}
