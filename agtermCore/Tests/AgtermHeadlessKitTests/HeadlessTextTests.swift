import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

extension HeadlessActionsTests {
    @Test(arguments: [false, true])
    func sessionTextReturnsHistoryWithoutRewritingItsContent(_ all: Bool) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let text = "first\n\n  indented café  \n\n"
        fixture.runner.enqueue(.ok(text))

        let response = try await fixture.dispatch(.sessionText) { $0.all = all }

        #expect(response.ok)
        #expect(response.result?.text == text)
        #expect(fixture.runner.calls.first?.arguments == ["history", ZmxSupport.daemonName(for: fixture.session.paneIdentity)])
    }

    @Test(arguments: [1, 2, 20])
    func sessionTextLinesCountContentAfterTrimmingBlankRows(_ lines: Int) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.ok("first\n\nlast  \n  \n\t\n"))
        let expected = lines == 1 ? "last  " : lines == 2 ? "\nlast  " : "first\n\nlast  "

        let response = try await fixture.dispatch(.sessionText) { $0.lines = lines }

        #expect(response.ok)
        #expect(response.result?.text == expected)
    }

    @Test(arguments: ["", "\n  \n\t\n"])
    func aBlankHistoryIsSuccessfulEmptyText(_ text: String) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.ok(text))

        let response = try await fixture.dispatch(.sessionText) { $0.lines = 3 }

        #expect(response.ok)
        #expect(response.result?.text == "")
    }

    @Test(arguments: [false, true])
    func sessionTextReadsTheSplitEvenWhenHidden(_ hidden: Bool) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        if hidden { fixture.store.setSplitVisibility(fixture.session.id, shown: false) }
        fixture.runner.enqueue(.ok("right"))

        let response = try await fixture.dispatch(.sessionText) { $0.pane = "right" }

        #expect(response.result?.text == "right")
        #expect(fixture.runner.calls.first?.arguments == ["history", ZmxSupport.daemonName(for: split)])
    }

    @Test func defaultTextFollowsFocusAndExplicitLeftOverridesIt() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        fixture.store.setSplitVisibility(fixture.session.id, shown: false)

        #expect(try await fixture.dispatch(.sessionText).ok)
        #expect(try await fixture.dispatch(.sessionText) { $0.pane = "left" }.ok)
        #expect(fixture.runner.calls.map(\.arguments) == [
            ["history", ZmxSupport.daemonName(for: split)],
            ["history", ZmxSupport.daemonName(for: fixture.session.paneIdentity)],
        ])
    }

    @Test func stablePaneTokenOverridesTheRoleAfterSwap() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let original = fixture.session.paneIdentity
        _ = try fixture.split()
        #expect(try await fixture.dispatch(.sessionSwap).ok)

        #expect(try await fixture.dispatch(.sessionText) { $0.pane = "left"; $0.paneID = original.uuidString }.ok)
        #expect(fixture.runner.calls.first?.arguments == ["history", ZmxSupport.daemonName(for: original)])
    }

    @Test(arguments: ["right", "scratch"])
    func aMissingTextPaneIsRefusedWithoutCallingZmx(_ pane: String) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionText) { $0.pane = pane }.ok == false)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test(arguments: [ZmxResult.timedOut, .failed(4, "broken"), .launchFailed("missing")])
    func aFailedHistoryReadIsAnErrorNotEmptyText(_ failure: ZmxResult) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(failure)

        let response = try await fixture.dispatch(.sessionText)

        #expect(!response.ok)
        #expect(response.error?.contains("history") == true)
        #expect(response.result?.text == nil)
    }

    @Test(arguments: [0, -1, 2])
    func invalidTextExtentsAreRejectedBeforeTheRunner(_ lines: Int) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionText) { $0.lines = lines; $0.all = lines > 0 }.ok == false)
        #expect(fixture.runner.calls.isEmpty)
    }
}
