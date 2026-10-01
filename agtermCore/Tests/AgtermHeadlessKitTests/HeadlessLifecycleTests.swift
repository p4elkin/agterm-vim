import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

extension HeadlessActionsTests {
    @Test func closeKillsEveryPaneDaemonAndRemovesTheSession() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        let left = ZmxSupport.daemonName(for: fixture.session.paneIdentity)

        let response = try await fixture.dispatch(.sessionClose)

        #expect(response.ok)
        #expect(fixture.runner.calls.map(\.arguments) == [["kill", left, "--force"], ["kill", ZmxSupport.daemonName(for: split), "--force"]])
        #expect(try await !fixture.sessionIDs().contains(fixture.session.id.uuidString))
        #expect(fixture.streams.closed == [fixture.session.id])
    }

    @Test func closeRemovesTheSessionEvenWhenAKillFails() async throws {
        let fixture = try HeadlessActionFixture(runner: FakeZmxRunner { _ in .failed(1, "no such session") })
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionClose).ok)
        #expect(try await !fixture.sessionIDs().contains(fixture.session.id.uuidString))
    }

    @Test func aBatchCloseClosesEveryTarget() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.dispatch(.sessionNew) { $0.command = "true" }
        let ids = try await fixture.sessionIDs()
        #expect(ids.count == 2)

        let request = HeadlessRequests.request(.sessionClose) { $0.targets = ids }
        let response = try #require(await ControlDispatcher(actions: fixture.actions).dispatch(request))

        #expect(response.ok)
        #expect(response.result?.affected == 2)
        #expect(try await fixture.sessionIDs().isEmpty)
    }

    @Test func aBatchCloseNamingOneSessionTwiceClosesItOnce() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let id = fixture.session.id.uuidString

        let request = HeadlessRequests.request(.sessionClose) { $0.targets = [id, id.lowercased()] }
        let response = try #require(await ControlDispatcher(actions: fixture.actions).dispatch(request))

        #expect(response.ok)
        #expect(response.result?.affected == 1)
        #expect(fixture.runner.calls.count == 1)
    }

    @Test func killingTheSplitDaemonClosesOnlyTheSplit() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()

        let response = try await fixture.dispatch(.zmxKill) {
            $0.pane = "right"
            $0.force = true
        }

        #expect(response.ok)
        #expect(response.result?.pane == "right")
        #expect(fixture.runner.calls.map(\.arguments) == [["kill", ZmxSupport.daemonName(for: split), "--force"]])
        #expect(try await fixture.node().hasSplit != true)
        #expect(try await fixture.sessionIDs().contains(fixture.session.id.uuidString))
    }

    @Test func killingTheOnlyDaemonClosesTheSession() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.zmxKill) {
            $0.pane = "left"
            $0.force = true
        }

        #expect(response.ok)
        #expect(try await !fixture.sessionIDs().contains(fixture.session.id.uuidString))
        #expect(fixture.streams.closed == [fixture.session.id])
    }

    @Test func killingTheLeftDaemonOfASplitSessionPromotesTheSplit() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()

        let response = try await fixture.dispatch(.zmxKill) {
            $0.pane = "left"
            $0.force = true
        }

        #expect(response.ok)
        #expect(fixture.session.paneIdentity == split)
        #expect(try await fixture.node().hasSplit != true)
        #expect(fixture.streams.closed.isEmpty)
    }

    @Test func aFailedKillLeavesThePaneOpen() async throws {
        let fixture = try HeadlessActionFixture(runner: FakeZmxRunner { _ in .timedOut })
        defer { fixture.cleanUp() }
        _ = try fixture.split()

        let response = try await fixture.dispatch(.zmxKill) {
            $0.pane = "right"
            $0.force = true
        }

        #expect(!response.ok)
        #expect(try await fixture.node().hasSplit == true)
    }

    @Test func killingAPaneTheSessionDoesNotHaveIsRefused() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.zmxKill) {
            $0.pane = "right"
            $0.force = true
        }

        #expect(!response.ok)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func renameReadsBackThroughTreeAndZmxTree() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.ok(fixture.listing))

        #expect(try await fixture.dispatch(.sessionRename) { $0.name = "renamed" }.ok)

        #expect(try await fixture.node().name == "renamed")
        #expect(try await fixture.dispatch(.zmxTree).result?.remote?.sessions.first?.name == "renamed")
    }
}
