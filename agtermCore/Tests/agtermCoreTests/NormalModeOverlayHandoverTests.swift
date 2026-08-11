import Foundation
import Testing
@testable import agtermCore

struct NormalModeOverlayHandoverTests {
    private let session = UUID()
    private let other = UUID()

    @Test func anOverlayAppearingOnAnUnchangedTargetYields() {
        var handover = NormalModeOverlayHandover()
        let plain = handover.step(session: session, pane: .left, ownsKeyboard: false)
        let opened = handover.step(session: session, pane: .left, ownsKeyboard: true)
        #expect(plain == false)
        #expect(opened == true)
        #expect(handover.isYielded)
    }

    @Test func theYieldHoldsWhileTheTargetStays() {
        var handover = NormalModeOverlayHandover()
        handover.step(session: session, pane: .left, ownsKeyboard: false)
        handover.step(session: session, pane: .left, ownsKeyboard: true)
        let second = handover.step(session: session, pane: .left, ownsKeyboard: true)
        let third = handover.step(session: session, pane: .left, ownsKeyboard: true)
        #expect(second == true)
        #expect(third == true)
    }

    @Test func theOverlayClosingClearsTheYield() {
        var handover = NormalModeOverlayHandover()
        handover.step(session: session, pane: .left, ownsKeyboard: false)
        handover.step(session: session, pane: .left, ownsKeyboard: true)
        let closed = handover.step(session: session, pane: .left, ownsKeyboard: false)
        #expect(closed == false)
        #expect(!handover.isYielded)
    }

    @Test func nothingRememberedDoesNotYield() {
        var handover = NormalModeOverlayHandover()
        let first = handover.step(session: session, pane: .left, ownsKeyboard: true)
        #expect(first == false)
    }

    @Test func arrivingOnAnotherSessionDoesNotYield() {
        var handover = NormalModeOverlayHandover()
        handover.step(session: session, pane: .left, ownsKeyboard: false)
        let arrival = handover.step(session: other, pane: .left, ownsKeyboard: true)
        let staying = handover.step(session: other, pane: .left, ownsKeyboard: true)
        #expect(arrival == false)
        #expect(staying == false)
    }

    @Test func arrivingOnAnotherPaneOfTheSameSessionDoesNotYield() {
        var handover = NormalModeOverlayHandover()
        handover.step(session: session, pane: .left, ownsKeyboard: false)
        let arrival = handover.step(session: session, pane: .right, ownsKeyboard: true)
        let staying = handover.step(session: session, pane: .right, ownsKeyboard: true)
        #expect(arrival == false)
        #expect(staying == false)
    }

    @Test func anOverlayAppearingAfterAnArrivalStillYields() {
        var handover = NormalModeOverlayHandover()
        handover.step(session: session, pane: .left, ownsKeyboard: false)
        let arrival = handover.step(session: other, pane: .left, ownsKeyboard: false)
        let opened = handover.step(session: other, pane: .left, ownsKeyboard: true)
        #expect(arrival == false)
        #expect(opened == true)
    }

    @Test func resetForgetsALiveYield() {
        var handover = NormalModeOverlayHandover()
        handover.step(session: session, pane: .left, ownsKeyboard: false)
        handover.step(session: session, pane: .left, ownsKeyboard: true)
        #expect(handover.isYielded)
        handover.reset()
        #expect(!handover.isYielded)
        let afterReset = handover.step(session: session, pane: .left, ownsKeyboard: true)
        #expect(afterReset == false)
    }

    @Test func aSessionlessTargetIsRememberedLikeAnyOther() {
        var handover = NormalModeOverlayHandover()
        handover.step(session: nil, pane: .left, ownsKeyboard: false)
        let opened = handover.step(session: nil, pane: .left, ownsKeyboard: true)
        #expect(opened == true)
    }
}
