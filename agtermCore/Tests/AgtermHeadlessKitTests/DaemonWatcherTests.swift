import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
struct DaemonWatcherTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func listing(_ panes: UUID...) -> ZmxResult {
        .ok(panes.map { "name=\(ZmxSupport.daemonName(for: $0))\tpid=42\tclients=0\n" }.joined())
    }

    private func watcher(_ fixture: HeadlessActionFixture, _ clock: Clock) -> DaemonWatcher {
        DaemonWatcher(headless: fixture.headless, now: { clock.now })
    }

    private func present(_ fixture: HeadlessActionFixture) async throws -> Bool {
        try await fixture.sessionIDs().contains(fixture.session.id.uuidString)
    }

    @Test func aSplitWhoseDaemonWasListedAndIsGoneCloses() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        let watcher = watcher(fixture, Clock())
        fixture.runner.enqueue(listing(fixture.session.paneIdentity, split))
        fixture.runner.enqueue(listing(fixture.session.paneIdentity))

        await watcher.poll()
        await watcher.poll()

        #expect(try await present(fixture))
        #expect(try await fixture.node().hasSplit != true)
    }

    @Test func aSessionWithNoPanesLeftClosesSplitFirst() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        let watcher = watcher(fixture, Clock())
        fixture.runner.enqueue(listing(fixture.session.paneIdentity, split))
        fixture.runner.enqueue(listing())

        await watcher.poll()
        await watcher.poll()

        #expect(try await !present(fixture))
        #expect(fixture.streams.closed == [fixture.session.id])
    }

    @Test func aPrimaryWhoseDaemonIsGonePromotesALiveSplit() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        let watcher = watcher(fixture, Clock())
        fixture.runner.enqueue(listing(fixture.session.paneIdentity, split))
        fixture.runner.enqueue(listing(split))

        await watcher.poll()
        await watcher.poll()

        #expect(try await present(fixture))
        #expect(fixture.session.paneIdentity == split)
    }

    @Test func aRestoredPaneNeverListedWaitsForTheStartupGrace() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let clock = Clock()
        let watcher = watcher(fixture, clock)

        fixture.runner.enqueue(listing())
        clock.advance(DaemonWatcher.startupGrace - 1)
        await watcher.poll()
        #expect(try await present(fixture))

        fixture.runner.enqueue(listing())
        clock.advance(1)
        await watcher.poll()
        #expect(try await !present(fixture))
    }

    @Test func aDaemonThatAppearsDuringTheGraceKeepsItsPane() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let clock = Clock()
        let watcher = watcher(fixture, clock)

        fixture.runner.enqueue(listing())
        clock.advance(60)
        await watcher.poll()
        fixture.runner.enqueue(listing(fixture.session.paneIdentity))
        clock.advance(60)
        await watcher.poll()
        fixture.runner.enqueue(listing(fixture.session.paneIdentity))
        clock.advance(DaemonWatcher.startupGrace)
        await watcher.poll()

        #expect(try await present(fixture))
    }

    @Test func aPaneCreatedAfterStartWaitsTheGraceFromItsCreation() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let clock = Clock()
        let watcher = watcher(fixture, clock)
        clock.advance(DaemonWatcher.startupGrace + 60)
        let created = try await fixture.dispatch(.sessionNew) { $0.command = "true" }
        let id = try #require(created.result?.id)

        fixture.runner.enqueue(listing(fixture.session.paneIdentity))
        await watcher.poll()
        fixture.runner.enqueue(listing(fixture.session.paneIdentity))
        clock.advance(DaemonWatcher.startupGrace - 1)
        await watcher.poll()
        #expect(try await fixture.sessionIDs().contains(id))

        fixture.runner.enqueue(listing(fixture.session.paneIdentity))
        clock.advance(1)
        await watcher.poll()
        #expect(try await !fixture.sessionIDs().contains(id))
    }

    @Test func aClosedPaneIsNoLongerTracked() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        let watcher = watcher(fixture, Clock())
        fixture.runner.enqueue(listing(fixture.session.paneIdentity, split))
        await watcher.poll()
        #expect(try await fixture.dispatch(.sessionSplitClose).ok)

        fixture.runner.enqueue(listing(fixture.session.paneIdentity))
        await watcher.poll()

        #expect(watcher.tracked == [fixture.session.paneIdentity])
    }

    @Test(arguments: [ZmxResult.timedOut, .failed(1, "boom"), .launchFailed("missing"), .ok("not a listing")])
    func aFailedListChangesNothing(_ failure: ZmxResult) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let clock = Clock()
        let watcher = watcher(fixture, clock)
        fixture.runner.enqueue(listing(fixture.session.paneIdentity))
        await watcher.poll()

        fixture.runner.enqueue(failure)
        clock.advance(DaemonWatcher.startupGrace * 2)
        await watcher.poll()

        #expect(try await present(fixture))
    }
}
