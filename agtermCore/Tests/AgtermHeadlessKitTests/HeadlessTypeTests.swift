import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

extension HeadlessActionsTests {
    private func typed(_ calls: [FakeZmxRunner.Call]) -> [[String]] {
        calls.map { $0.arguments + [String(decoding: $0.input ?? Data(), as: UTF8.self)] }
    }

    @Test(arguments: [
        ("echo hi\n", ["echo hi", "\r"]),
        ("first\nsecond\n", ["first\rsecond", "\r"]),
        ("no return", ["no return"]),
        ("\n", ["\r"]),
    ])
    func textReachesTheLeftDaemonWithTheReturnSeparate(_ text: String, _ writes: [String]) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let daemon = ZmxSupport.daemonName(for: fixture.session.paneIdentity)

        let response = try await fixture.dispatch(.sessionType) { $0.text = text }

        #expect(response.ok)
        #expect(response.result?.id == fixture.session.id.uuidString)
        #expect(typed(fixture.runner.calls) == writes.map { ["type", daemon, $0] })
    }

    @Test func theRightPaneTypesIntoItsOwnDaemon() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()

        #expect(try await fixture.dispatch(.sessionType) { $0.text = "ls\n"; $0.pane = "right" }.ok)

        #expect(typed(fixture.runner.calls) == [["type", ZmxSupport.daemonName(for: split), "ls"],
                                                 ["type", ZmxSupport.daemonName(for: split), "\r"]])
    }

    @Test func aRightPaneWithNoDaemonIsRefusedByName() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.sessionType) { $0.text = "ls\n"; $0.pane = "right" }

        #expect(response.error == "no right pane daemon for session \(fixture.session.id.uuidString)")
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func theScratchPaneIsRefused() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.sessionType) { $0.text = "ls\n"; $0.pane = "scratch" }

        #expect(response.error == "a headless session has no scratch terminal")
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func selectIsRefusedAndPlainTextIsStillTyped() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let selected = try await fixture.dispatch(.sessionType) { $0.text = "ls"; $0.select = true }

        #expect(selected.error == "session.type --select is not available on a headless origin: it has no selection")
        #expect(fixture.runner.calls.isEmpty)
        #expect(try await fixture.dispatch(.sessionType) { $0.text = "ls" }.ok)
        #expect(fixture.runner.calls.count == 1)
    }

    @Test func aFailedTypeIsReportedAndNeverRetried() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.failed(1, "no such session"))

        let response = try await fixture.dispatch(.sessionType) { $0.text = "ls\n" }

        #expect(response.error == "the pane's zmx daemon did not accept the input: zmx type failed (1): no such session")
        #expect(fixture.runner.calls.count == 1)
    }

    @Test func aFailedReturnSaysNotToRetype() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.ok(""))
        fixture.runner.enqueue(.timedOut)

        let response = try await fixture.dispatch(.sessionType) { $0.text = "ls\n" }

        #expect(response.error == "text typed, but its final Return could not be confirmed; do not retype the text")
        #expect(fixture.runner.calls.count == 2)
    }

    @Test func twoCallsOnOnePaneNeverInterleave() async throws {
        let runner = FakeZmxRunner { _ in
            Thread.sleep(forTimeInterval: 0.02)
            return .ok("")
        }
        let fixture = try HeadlessActionFixture(runner: runner)
        defer { fixture.cleanUp() }

        async let first = fixture.dispatch(.sessionType) { $0.text = "one\n" }
        async let second = fixture.dispatch(.sessionType) { $0.text = "two\n" }
        #expect(try await first.ok)
        #expect(try await second.ok)

        let writes = typed(runner.calls).map { $0.last ?? "" }
        #expect(writes == ["one", "\r", "two", "\r"] || writes == ["two", "\r", "one", "\r"])
    }

    @Test func typedInputClearsTheTypedPanesStatusForTheViewers() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let viewer = try HeadlessAskTests.Sink(fixture, mode: .mirror)
        #expect(try await fixture.dispatch(.sessionStatus) { $0.status = "blocked" }.ok)

        #expect(try await fixture.dispatch(.sessionType) { $0.text = "y\n" }.ok)

        #expect(fixture.session.agentIndicator.status == .idle)
        #expect(viewer.bodies.last == .status(nil))
    }

    @Test func typingLeavesAnotherPanesStatusAndAnEmptyPayloadClearsNothing() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.split()
        #expect(try await fixture.dispatch(.sessionStatus) { $0.status = "blocked"; $0.pane = "right" }.ok)
        #expect(try await fixture.dispatch(.sessionType) { $0.text = "y\n" }.ok)
        #expect(try await fixture.dispatch(.sessionType) { $0.text = ""; $0.pane = "right" }.ok)

        #expect(fixture.session.agentIndicator.status == .blocked)
        #expect(fixture.runner.calls.count == 2)
    }
}
