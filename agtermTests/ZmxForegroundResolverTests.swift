import agtermCore
import os
import XCTest
@testable import agterm

/// The app-side half of resolving past the wrapper: when the resolver spends a `zmx list` subprocess and
/// when it must not. The selection itself is host-free (`ZmxForegroundSelectionTests`).
@MainActor
final class ZmxForegroundResolverTests: XCTestCase {
    private let sessionID = UUID(uuidString: "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F")!
    private var leftKey: String { "\(sessionID.uuidString)-left" }
    private var wrapperArgv: [String] { ["/opt/homebrew/bin/zmx", "attach", leftKey] }

    /// Counts the listings a resolver asks for; `entries` nil is an unreadable `zmx list`.
    private final class ListingSpy: Sendable {
        let entries: [ZmxListParser.Entry]?
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var calls: Int { count.withLock { $0 } }

        init(entries: [ZmxListParser.Entry]?) { self.entries = entries }

        func recordCall() { count.withLock { $0 += 1 } }
    }

    private func resolver(_ spy: ListingSpy) -> ZmxForegroundResolver {
        var client = ZmxClient.noop
        client.list = {
            spy.recordCall()
            return spy.entries
        }
        return ZmxForegroundResolver(client: client)
    }

    func testResolvesTheLeaderOfAWrappedPane() {
        let spy = ListingSpy(entries: [.init(name: leftKey, clients: 1, leaderPID: 74149)])

        XCTAssertEqual(resolver(spy).leaderPID(behind: wrapperArgv), 74149)
    }

    func testListsOnceForEveryPaneInOneTreeBuild() {
        let spy = ListingSpy(entries: [.init(name: leftKey, clients: 1, leaderPID: 74149)])
        let resolver = resolver(spy)

        for _ in 0..<5 { _ = resolver.leaderPID(behind: wrapperArgv) }

        XCTAssertEqual(spy.calls, 1)
    }

    func testAnUnwrappedPaneNeverSpawnsZmx() {
        let spy = ListingSpy(entries: [])
        let resolver = resolver(spy)

        XCTAssertNil(resolver.leaderPID(behind: ["-zsh"]))
        XCTAssertNil(resolver.leaderPID(behind: ["/opt/homebrew/bin/zmx", "attach", "dam"]))
        XCTAssertEqual(spy.calls, 0)
    }

    func testAnUnreadableListingIsNotRetried() {
        let spy = ListingSpy(entries: nil)
        let resolver = resolver(spy)

        for _ in 0..<3 { XCTAssertNil(resolver.leaderPID(behind: wrapperArgv)) }

        XCTAssertEqual(spy.calls, 1)
    }

    // MARK: - the syscall the resolved leader is fed to

    /// The second real step past the wrapper: a session leader's pid to the foreground process group of the
    /// pty it owns. The injected-listing tests above stop at the leader, so without this the `e_tpgid` read
    /// is unverified — and it is exactly the read a zmx daemon's pty is inspected through, a descriptor this
    /// process does not hold. A pty of its own stands in for the daemon; the test host itself has no
    /// controlling terminal under `xcodebuild`.
    func testTerminalForegroundGroupIsThePtysOwnForegroundGroup() throws {
        let argv: [String] = ["/bin/sh", "-c", "exec sleep 30"]
        var arguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        arguments.append(nil)
        defer { arguments.forEach { free($0) } }
        var controller: Int32 = -1
        let child = forkpty(&controller, nil, nil, nil)
        try XCTSkipIf(child < 0, "forkpty failed: \(errno)")
        if child == 0 {
            execv("/bin/sh", &arguments)
            _exit(127)
        }
        defer {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
            close(controller)
        }
        var expected = tcgetpgrp(controller)
        let deadline = Date().addingTimeInterval(2)
        while expected <= 0, Date() < deadline {
            usleep(5_000)
            expected = tcgetpgrp(controller)
        }
        XCTAssertGreaterThan(expected, 0, "the child never claimed the pty's foreground group")
        XCTAssertEqual(ForegroundProcess.terminalForegroundGroup(of: child), expected)
    }

    func testTerminalForegroundGroupOfADeadProcessIsNil() {
        // a pid no process can hold: `kern.maxproc` caps well below this on every supported machine
        XCTAssertNil(ForegroundProcess.terminalForegroundGroup(of: 0x7FFF_FFFE))
    }
}
