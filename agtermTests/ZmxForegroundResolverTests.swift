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
}
