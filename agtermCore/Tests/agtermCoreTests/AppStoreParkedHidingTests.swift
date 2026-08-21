import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreParkedHidingTests {
    @Test func unparkedRowStaysVisibleWithHidingOn() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        store.hideParked = true
        store.selectedSessionID = nil
        #expect(store.isRowVisible(session))
    }

    @Test func parkedRowStaysVisibleWithHidingOff() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        store.setParked(true, forSession: session.id)
        store.selectedSessionID = nil
        #expect(store.isRowVisible(session))
    }

    @Test func parkedRowHiddenWhenHidingOnAndNothingExemptsIt() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        store.setParked(true, forSession: session.id)
        store.hideParked = true
        store.selectedSessionID = nil
        #expect(!store.isRowVisible(session))
    }

    @Test func revealedWorkspaceKeepsItsParkedRowsDrawn() {
        let store = makeStore()
        let revealed = store.addWorkspace(name: "revealed")
        let hidden = store.addWorkspace(name: "hidden")
        let kept = try! #require(store.addSession(toWorkspace: revealed.id, cwd: "/a"))
        let gone = try! #require(store.addSession(toWorkspace: hidden.id, cwd: "/b"))
        store.setParked(true, forSession: kept.id)
        store.setParked(true, forSession: gone.id)
        store.hideParked = true
        store.parkedRevealedWorkspaceIDs = [revealed.id]
        store.selectedSessionID = nil
        #expect(store.isRowVisible(kept))
        #expect(!store.isRowVisible(gone))
    }

    @Test func selectedRowSurvivesParkingAndHidesOnceSelectionMoves() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let parked = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let other = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.selectSession(parked.id)
        store.setParked(true, forSession: parked.id)
        store.hideParked = true
        #expect(store.isRowVisible(parked))
        store.selectSession(other.id)
        #expect(!store.isRowVisible(parked))
    }

    @Test func applyHideTurnsTheWindowFlagOnAndShowOff() {
        let store = makeStore()
        store.applyParkedVisibility(.hide)
        #expect(store.hideParked)
        store.applyParkedVisibility(.show)
        #expect(!store.hideParked)
    }

    @Test func applyToggleFlipsTheWindowFlagBothWays() {
        let store = makeStore()
        store.applyParkedVisibility(.toggle)
        #expect(store.hideParked)
        store.applyParkedVisibility(.toggle)
        #expect(!store.hideParked)
    }

    @Test func windowScopeLeavesTheRevealedSetAlone() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.parkedRevealedWorkspaceIDs = [ws.id]
        store.applyParkedVisibility(.hide)
        #expect(store.parkedRevealedWorkspaceIDs == [ws.id])
    }

    @Test func workspaceShowMarksItRevealedAndHideUnmarks() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.applyParkedVisibility(.show, toWorkspace: ws.id)
        #expect(store.parkedRevealedWorkspaceIDs == [ws.id])
        store.applyParkedVisibility(.hide, toWorkspace: ws.id)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
    }

    @Test func workspaceToggleFlipsMembership() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.applyParkedVisibility(.toggle, toWorkspace: ws.id)
        #expect(store.parkedRevealedWorkspaceIDs == [ws.id])
        store.applyParkedVisibility(.toggle, toWorkspace: ws.id)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
    }

    @Test func workspaceScopeLeavesTheWindowFlagAlone() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.hideParked = true
        store.applyParkedVisibility(.show, toWorkspace: ws.id)
        #expect(store.hideParked)
        store.applyParkedVisibility(.hide, toWorkspace: ws.id)
        #expect(store.hideParked)
    }

    @Test func markingRevealedIsRefusedForAnIdNamingNoWorkspace() {
        let store = makeStore()
        let phantom = UUID()
        store.applyParkedVisibility(.show, toWorkspace: phantom)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
        store.applyParkedVisibility(.toggle, toWorkspace: phantom)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
    }

    @Test func unmarkingAStaleIdStaysPossible() {
        let store = makeStore()
        let stale = UUID()
        store.parkedRevealedWorkspaceIDs = [stale]
        store.applyParkedVisibility(.hide, toWorkspace: stale)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
    }

    @Test func everywhereClearsTheSetAndDrivesTheFlag() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.parkedRevealedWorkspaceIDs = [ws.id]
        store.applyParkedVisibilityEverywhere(.hide)
        #expect(store.hideParked)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
    }

    @Test func everywhereShowClearsTheSetAndTheFlag() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.hideParked = true
        store.parkedRevealedWorkspaceIDs = [ws.id]
        store.applyParkedVisibilityEverywhere(.show)
        #expect(!store.hideParked)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
    }

    @Test func everywhereToggleFlipsTheFlagFromItsCurrentState() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.hideParked = true
        store.parkedRevealedWorkspaceIDs = [ws.id]
        store.applyParkedVisibilityEverywhere(.toggle)
        #expect(!store.hideParked)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
    }

    @Test func predicateMutatesNothing() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        store.setParked(true, forSession: session.id)
        store.hideParked = true
        store.parkedRevealedWorkspaceIDs = []
        _ = store.isRowVisible(session)
        #expect(store.hideParked)
        #expect(store.parkedRevealedWorkspaceIDs.isEmpty)
        #expect(session.parked)
        #expect(store.selectedSessionID == session.id)
    }
}
