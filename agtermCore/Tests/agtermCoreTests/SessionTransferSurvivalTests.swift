import Foundation
import Testing
@testable import agtermCore

@MainActor
@Suite struct SessionTransferSurvivalTests {
    @Test func defaultPrepareForTransferTearsDownOnce() {
        let surface = PlainSurface()
        surface.prepareForTransfer()
        #expect(surface.teardownCount == 1)
    }

    @Test func overridingSurfaceIsDispatchedThroughTheExistential() {
        let override = OverridingSurface()
        let existential: any TerminalSurface = override
        existential.prepareForTransfer()
        #expect(override.prepareCount == 1)
        #expect(override.teardownCount == 0)
    }

    @Test func zmxBackedPrimarySurvives() {
        let session = Session(initialCwd: "/tmp")
        session.surface = PlainSurface(backedByZmx: true)
        #expect(session.canSurviveTransfer)
    }

    @Test func zmxBackedPrimaryAndSplitSurvive() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.surface = PlainSurface(backedByZmx: true)
        session.splitSurface = PlainSurface(backedByZmx: true)
        #expect(session.canSurviveTransfer)
    }

    @Test func splitNotBackedByZmxDoesNotSurvive() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.surface = PlainSurface(backedByZmx: true)
        session.splitSurface = PlainSurface(backedByZmx: false)
        #expect(!session.canSurviveTransfer)
    }

    @Test func plainUnwrappedPrimaryDoesNotSurvive() {
        let session = Session(initialCwd: "/tmp")
        session.surface = PlainSurface(backedByZmx: false)
        #expect(!session.canSurviveTransfer)
    }

    @Test func unrealizedSlotsSurvive() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        #expect(session.canSurviveTransfer)
    }

    // zmxBacking(for:) would answer the nil split from its zmx-backed sibling; the rule reads each slot itself.
    @Test func nilSplitBesideAPlainPrimaryDoesNotBorrowTheSiblingAnswer() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.surface = PlainSurface(backedByZmx: false)
        #expect(!session.canSurviveTransfer)
    }

    @Test func remoteRowSurvives() {
        let session = Session(initialCwd: "/tmp", remoteHost: "p4linux")
        session.surface = PlainSurface(backedByZmx: false)
        #expect(session.canSurviveTransfer)
    }
}

@MainActor
private final class PlainSurface: TerminalSurface {
    let backedByZmx: Bool
    let paneToken = ""
    let isRealized = true
    var teardownCount = 0
    init(backedByZmx: Bool = false) { self.backedByZmx = backedByZmx }
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() {}
}

@MainActor
private final class OverridingSurface: TerminalSurface {
    let paneToken = ""
    let isRealized = true
    var teardownCount = 0
    var prepareCount = 0
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() {}
    func prepareForTransfer() { prepareCount += 1 }
}
