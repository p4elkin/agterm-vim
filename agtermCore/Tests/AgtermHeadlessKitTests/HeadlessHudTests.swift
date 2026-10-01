import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
struct HeadlessHudTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_789_000_000)
    }

    final class Sink: PresentationSink {
        var huds: [PresentationHud?] = []

        init(_ fixture: HeadlessActionFixture) throws {
            try fixture.headless.hub.subscribe(session: fixture.session.id,
                                              hello: PresentationHello(version: 1, kinds: ["hud"], mode: .mirror),
                                              sink: self) {
                fixture.store.presentationSnapshot(forSession: fixture.session.id)
            }
        }

        func offer(_ frame: PresentationFrame) -> Bool {
            if case .hud(let hud) = frame.body { huds.append(hud) }
            return true
        }

        func close(_: PresentationHub.CloseReason) {}
    }

    @Test func openPublishesTheSpecAndStablePane() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        let sink = try Sink(fixture)

        let response = try await fixture.dispatch(.sessionHudOpen) {
            $0.message = "working"; $0.detail = "phase"; $0.spinner = "bar"; $0.sizePercent = 40; $0.pane = "right"
        }

        #expect(response.ok)
        #expect(response.result?.id == fixture.session.id.uuidString)
        let hud = try #require(sink.huds.last.flatMap { $0 })
        #expect(hud.spec == HudSpec(message: "working", detail: "phase", spinner: .bar, sizePercent: 40))
        #expect(hud.pane == .identity(split))
        #expect(hud.remaining == nil)
        #expect(fixture.session.overlayCommand == "")
        #expect(fixture.session.hudFile == "")
        #expect(fixture.session.overlaySizePercent == 40)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func updateRepublishesWithAHigherGeneration() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try Sink(fixture)
        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "old" }.ok)
        let first = try #require(sink.huds.last.flatMap { $0 })

        #expect(try await fixture.dispatch(.sessionHudUpdate) { $0.message = "new"; $0.pane = "left" }.ok)

        let updated = try #require(sink.huds.last.flatMap { $0 })
        #expect(updated.spec.message == "new")
        #expect(updated.pane == .identity(fixture.session.paneIdentity))
        #expect(updated.generation > first.generation)
    }

    @Test func closePublishesAnEmptyHud() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try Sink(fixture)
        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "open" }.ok)

        #expect(try await fixture.dispatch(.sessionHudClose).ok)

        #expect(!fixture.session.hudActive)
        #expect(sink.huds.count == 2)
        #expect(sink.huds.last == .some(nil))
    }

    @Test func autoHidePublishesEmptyHudAtTheInjectedDeadline() async throws {
        let clock = Clock()
        let fixture = try HeadlessActionFixture(hudClock: { clock.now })
        defer { fixture.cleanUp() }
        let sink = try Sink(fixture)
        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "open"; $0.hideAfter = 2 }.ok)
        #expect(sink.huds.last.flatMap { $0 }?.remaining == 2)

        clock.now += 1
        fixture.actions.expireHuds()
        #expect(fixture.session.hudActive)
        clock.now += 1
        fixture.actions.expireHuds()

        #expect(!fixture.session.hudActive)
        #expect(sink.huds.last == .some(nil))
    }

    @Test func aSplitHudClosesWithItsPane() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.split()
        let sink = try Sink(fixture)
        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "split"; $0.pane = "right" }.ok)

        #expect(try await fixture.dispatch(.sessionSplitClose).ok)

        #expect(!fixture.session.hudActive)
        #expect(sink.huds.last == .some(nil))
    }

    @Test func anUpdateRearmsTheDeadlineAndZeroCancelsIt() async throws {
        let clock = Clock()
        let fixture = try HeadlessActionFixture(hudClock: { clock.now })
        defer { fixture.cleanUp() }
        let sink = try Sink(fixture)
        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "open"; $0.hideAfter = 2 }.ok)
        clock.now += 1
        #expect(try await fixture.dispatch(.sessionHudUpdate) { $0.message = "updated"; $0.hideAfter = 2 }.ok)
        clock.now += 1
        fixture.actions.expireHuds()
        #expect(fixture.session.hudActive)
        #expect(try await fixture.dispatch(.sessionHudUpdate) { $0.message = "persistent"; $0.hideAfter = 0 }.ok)
        clock.now += 10
        fixture.actions.expireHuds()
        #expect(fixture.session.hudActive)
        #expect(sink.huds.last.flatMap { $0 }?.remaining == nil)
    }

    @Test func paneTokensOverrideRolesAndHiddenSplitHudsRemainAddressable() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let split = try fixture.split()
        fixture.store.setSplitVisibility(fixture.session.id, shown: false)
        let sink = try Sink(fixture)

        #expect(try await fixture.dispatch(.sessionHudOpen) {
            $0.message = "hidden"; $0.pane = "left"; $0.paneID = split.uuidString
        }.ok)

        #expect(sink.huds.last.flatMap { $0 }?.pane == .identity(split))
    }

    @Test func invalidPlacementDoesNotReplaceTheExistingHud() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try Sink(fixture)
        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "keep" }.ok)
        let count = sink.huds.count

        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "bad"; $0.pane = "right" }.ok == false)
        #expect(try await fixture.dispatch(.sessionHudUpdate) { $0.message = "bad"; $0.paneID = "unknown" }.ok == false)

        #expect(fixture.session.hudSpec?.message == "keep")
        #expect(sink.huds.count == count)
    }

    @Test func noHudAndProgramOccupancyAreRefused() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try Sink(fixture)
        #expect(try await fixture.dispatch(.sessionHudUpdate) { $0.message = "missing" }.ok == false)
        #expect(try await fixture.dispatch(.sessionHudClose).ok == false)
        #expect(fixture.store.openOverlay(fixture.session.id, command: "program"))

        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "bad" }.ok == false)
        #expect(try await fixture.dispatch(.sessionHudClose).ok == false)

        #expect(fixture.session.overlayCommand == "program")
        #expect(sink.huds.isEmpty)
    }

    @Test(arguments: [nil, 1, 100] as [Int?])
    func widthUsesTheCoreFallbackAndClamp(_ percent: Int?) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        #expect(try await fixture.dispatch(.sessionHudOpen) { $0.message = "size"; $0.sizePercent = percent }.ok)
        #expect(fixture.session.overlaySizePercent == HudLayout.clampSizePercent(percent ?? HudLayout.maxSizePercent))
        #expect(fixture.session.hudHeightPercent == HudLayout.minSizePercent)
    }
}
