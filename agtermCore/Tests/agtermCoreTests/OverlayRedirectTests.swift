import Foundation
import Testing
@testable import agtermCore

struct OverlayRedirectTests {
    private let mirrors = OverlayMirrorSource(host: "p4studio.local", session: "s1")
    private let now: Double = 1_000_000

    private func viewer(confirmedAt: Double) -> OverlayViewer {
        OverlayViewer(host: "p4air.local", row: "r7", confirmedAt: confirmedAt)
    }

    @Test func toggleOffGivesLocalWithAMirrorsPairing() {
        let outcome = OverlayRedirect.outcome(enabled: false, mirrors: mirrors, viewer: nil, now: now)
        #expect(outcome == .local)
    }

    @Test func toggleOffGivesLocalWithAViewerPairing() {
        let outcome = OverlayRedirect.outcome(enabled: false, mirrors: nil, viewer: viewer(confirmedAt: now), now: now)
        #expect(outcome == .local)
    }

    @Test func toggleOnWithNoPairingGivesLocal() {
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: nil, now: now) == .local)
    }

    @Test func aMirrorsPairingGivesMirrorOfItsHost() {
        let outcome = OverlayRedirect.outcome(enabled: true, mirrors: mirrors, viewer: nil, now: now)
        #expect(outcome == .mirrorOf(host: "p4studio.local", cwd: nil))
    }

    @Test func aViewerPairingGivesWatchedByItsHostAndRow() {
        let outcome = OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: viewer(confirmedAt: now), now: now)
        #expect(outcome == .watchedBy(host: "p4air.local", row: "r7"))
    }

    @Test func aViewerOlderThanTheWindowGivesLocal() {
        let stale = viewer(confirmedAt: now - OverlayRedirect.stalenessWindow - 1)
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: stale, now: now) == .local)
    }

    @Test func aViewerExactlyAtTheWindowIsStillFresh() {
        let edge = viewer(confirmedAt: now - OverlayRedirect.stalenessWindow)
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: edge, now: now)
            == .watchedBy(host: "p4air.local", row: "r7"))
    }

    /// The two machines' clocks are not in step, so a confirmation stamped slightly ahead of us is not stale.
    @Test func aViewerConfirmedInTheFutureIsFresh() {
        let ahead = viewer(confirmedAt: now + 5)
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: ahead, now: now)
            == .watchedBy(host: "p4air.local", row: "r7"))
    }

    @Test func theStalenessWindowIsAParameter() {
        let old = viewer(confirmedAt: now - 100)
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: old, now: now, staleness: 200)
            == .watchedBy(host: "p4air.local", row: "r7"))
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: old, now: now, staleness: 50) == .local)
    }

    @Test func aMirroredRowWinsOverAViewerOnTheSameSession() {
        let outcome = OverlayRedirect.outcome(enabled: true, mirrors: mirrors, viewer: viewer(confirmedAt: now), now: now)
        #expect(outcome == .mirrorOf(host: "p4studio.local", cwd: nil))
    }

    // MARK: - the workstation's working directory rides on the pairing

    // The bug this closes: a mirrored row's own cwd is always `$HOME`, a path that exists on BOTH machines,
    // so the redirect's `cd` succeeded and the overlay opened in the wrong directory with no error.
    @Test func aMirrorsPairingCarriesItsCwdIntoTheOutcome() {
        let paired = OverlayMirrorSource(host: "p4studio.local", session: "s1", cwd: "/w/agterm")
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: paired, viewer: nil, now: now)
            == .mirrorOf(host: "p4studio.local", cwd: "/w/agterm"))
    }

    @Test func aMirrorsPairingWithNoCwdGivesANilCwd() {
        let outcome = OverlayRedirect.outcome(enabled: true, mirrors: mirrors, viewer: nil, now: now)
        #expect(outcome == .mirrorOf(host: "p4studio.local", cwd: nil))
    }

    @Test func theCwdReachesTheWireAnswer() {
        let paired = OverlayMirrorSource(host: "p4studio.local", session: "s1", cwd: "/w/agterm")
        let answer = OverlayRedirect.outcome(enabled: true, mirrors: paired, viewer: nil, now: now).redirect
        #expect(answer == ControlOverlayRedirect(outcome: .mirrorOf, host: "p4studio.local", cwd: "/w/agterm"))
    }

    @Test func aWatchedByAnswerCarriesNoCwd() {
        let answer = OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: viewer(confirmedAt: now),
                                             now: now).redirect
        #expect(answer?.cwd == nil)
    }

    @Test func aCwdDoesNotChangeThePillColour() {
        let paired = OverlayMirrorSource(host: "p4studio.local", session: "s1", cwd: "/w/agterm")
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: paired, viewer: nil, now: now).pill == .green)
    }

    @Test func theDefaultWindowIsTwiceTheMirrorInterval() {
        #expect(OverlayRedirect.stalenessWindow == 40)
    }

    @Test func localIsGrey() {
        #expect(OverlayRedirectOutcome.local.pill == .grey)
    }

    @Test func mirrorOfIsGreen() {
        #expect(OverlayRedirectOutcome.mirrorOf(host: "p4studio.local", cwd: nil).pill == .green)
    }

    @Test func watchedByIsRed() {
        #expect(OverlayRedirectOutcome.watchedBy(host: "p4air.local", row: "r7").pill == .red)
    }

    @Test func theToggleBeingOffLeavesThePillGrey() {
        let outcome = OverlayRedirect.outcome(enabled: false, mirrors: mirrors, viewer: nil, now: now)
        #expect(outcome.pill == .grey)
    }

    @Test func aPairinglessSessionLeavesThePillGrey() {
        #expect(OverlayRedirect.outcome(enabled: true, mirrors: nil, viewer: nil, now: now).pill == .grey)
    }
}
