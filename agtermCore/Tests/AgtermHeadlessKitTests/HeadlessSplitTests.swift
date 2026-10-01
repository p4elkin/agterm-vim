import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

extension HeadlessActionsTests {
    @Test func splitSwapAndClosePublishTheLivePaneLayout() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try SplitLayoutSink(fixture)
        let primary = fixture.session.paneIdentity

        #expect(try await fixture.dispatch(.sessionSplit) { $0.mode = "on"; $0.command = "true"; $0.axis = "horizontal" }.ok)
        let split = try #require(fixture.session.splitPaneIdentity)
        let call = try #require(fixture.runner.calls.first)
        #expect(call.arguments == ["run", ZmxSupport.daemonName(for: split), "-d", "sh", "-c", "true"])
        #expect(call.environment["AGTERM_PANE"] == "right")
        #expect(call.environment["AGTERM_PANE_ID"] == split.uuidString)
        #expect(call.environment["AGTERM_SESSION_ID"] == fixture.session.id.uuidString)
        #expect(call.environment["AGTERM_STATE_DIR"] == fixture.headless.config.stateDirectory)
        #expect(call.workingDirectory == fixture.session.effectiveCwd)
        #expect(fixture.session.allPanesBackedByZmx)
        #expect(sink.layouts == [PresentationLayout(panes: [primary, split], primary: primary, axis: "horizontal", shown: true)])

        #expect(try await fixture.dispatch(.sessionSwap).ok)
        #expect(fixture.session.paneIdentity == split)
        #expect(fixture.session.surface?.paneToken == split.uuidString)
        #expect(fixture.session.splitSurface?.paneToken == primary.uuidString)
        #expect(sink.layouts.last == PresentationLayout(panes: [split, primary], primary: split, axis: "horizontal", shown: true))

        #expect(try await fixture.dispatch(.sessionSplitClose).ok)
        #expect(fixture.runner.calls.last?.arguments == ["kill", ZmxSupport.daemonName(for: primary), "--force"])
        #expect(!fixture.session.hasSplit)
        #expect(sink.layouts.last == PresentationLayout(panes: [split], primary: split, shown: false))
        #expect(fixture.streams.closed.isEmpty)
    }

    @Test func hidingAndShowingKeepsTheSplitDaemonAndIdentity() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try SplitLayoutSink(fixture)
        #expect(try await fixture.dispatch(.sessionSplit) { $0.mode = "on" }.ok)
        let split = try #require(fixture.session.splitPaneIdentity)

        #expect(try await fixture.dispatch(.sessionSplit) { $0.mode = "off" }.ok)
        #expect(fixture.session.hasSplit)
        #expect(!fixture.session.isSplit)
        #expect(sink.layouts.last?.panes.count == 2)
        #expect(sink.layouts.last?.shown == false)
        #expect(try await fixture.dispatch(.sessionSwap).ok)
        #expect(fixture.session.paneIdentity == split)
        #expect(!fixture.session.isSplit)
        #expect(try await fixture.dispatch(.sessionSplit) { $0.mode = "on"; $0.axis = "horizontal" }.ok)
        #expect(fixture.runner.calls.count == 1)
        #expect(fixture.session.isSplit)
        #expect(fixture.session.splitAxis == .topBottom)
    }

    @Test func togglingAnAxisTransposesThenHidesWithoutSpawningAgain() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        #expect(try await fixture.dispatch(.sessionSplit).ok)
        #expect(try await fixture.dispatch(.sessionSplit) { $0.axis = "horizontal" }.ok)
        #expect(fixture.session.isSplit)
        #expect(fixture.session.splitAxis == .topBottom)
        #expect(try await fixture.dispatch(.sessionSplit) { $0.axis = "horizontal" }.ok)
        #expect(!fixture.session.isSplit)
        #expect(fixture.runner.calls.count == 1)
    }

    @Test func aFailedSplitCleansItsDaemonWithoutPublishingAPane() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try SplitLayoutSink(fixture)
        fixture.runner.enqueue(.timedOut)

        #expect(try await fixture.dispatch(.sessionSplit) { $0.mode = "on" }.ok == false)
        #expect(!fixture.session.hasSplit)
        #expect(fixture.session.splitPaneIdentity == nil)
        #expect(fixture.session.splitSurface == nil)
        #expect(sink.layouts.isEmpty)
        #expect(fixture.runner.calls.count == 2)
        let created = try #require(fixture.runner.calls.first)
        #expect(fixture.runner.calls.last?.arguments == ["kill", created.arguments[1], "--force"])
    }

    @Test func aCommandCannotReplaceAHiddenSplit() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        fixture.store.setSplitVisibility(fixture.session.id, shown: false)

        #expect(try await fixture.dispatch(.sessionSplit) { $0.mode = "on"; $0.command = "true" }.ok == false)
        #expect(fixture.runner.calls.isEmpty)
        #expect(fixture.session.splitPaneIdentity == split)
        #expect(!fixture.session.isSplit)
    }

    @Test(arguments: ["off", "toggle", "invalid"])
    func aSplitCommandRequiresModeOn(_ mode: String) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionSplit) { $0.mode = mode; $0.command = "true" }.ok == false)
        #expect(fixture.runner.calls.isEmpty)
        #expect(!fixture.session.hasSplit)
    }

    @Test func closingAnAbsentSplitIsIdempotentAndAFailedKillPreservesIt() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        #expect(try await fixture.dispatch(.sessionSplitClose).ok)
        #expect(fixture.runner.calls.isEmpty)
        #expect(try await fixture.dispatch(.sessionSwap).ok == false)
        let split = try fixture.split()
        fixture.runner.enqueue(.failed(1, "no reply"))

        #expect(try await fixture.dispatch(.sessionSplitClose).ok == false)
        #expect(fixture.session.splitPaneIdentity == split)
        #expect(fixture.session.hasSplit)
    }
}

@MainActor
private final class SplitLayoutSink: PresentationSink {
    var layouts: [PresentationLayout] = []

    init(_ fixture: HeadlessActionFixture) throws {
        try fixture.headless.hub.subscribe(session: fixture.session.id,
                                          hello: PresentationHello(version: 1, kinds: ["layout"], mode: .mirror), sink: self) {
            fixture.store.presentationSnapshot(forSession: fixture.session.id)
        }
    }

    func offer(_ frame: PresentationFrame) -> Bool {
        if case .layout(let layout) = frame.body { layouts.append(layout) }
        return true
    }

    func close(_ reason: PresentationHub.CloseReason) {}
}
