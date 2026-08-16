import Foundation
import Testing
@testable import agtermCore

/// The dwell threshold before a selection joins the Ctrl-Tab order. Every timing case sets a dwell far
/// longer than the test can run and drives the fire with `recencyDwellDebouncer.flush()`, so nothing sleeps.
@MainActor
struct AppStoreRecencyDwellTests {
    private let longDwell: TimeInterval = 100

    /// Three sessions in one workspace, the dwell armed and the recency stack emptied of the ids `addSession`
    /// recorded on the way in, so each case starts from "nothing has been dwelt in yet".
    private func makeDwellStore() -> (AppStore, [Session]) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "w")
        let sessions = ["/a", "/b", "/c"].map { store.addSession(toWorkspace: workspace.id, cwd: $0)! }
        store.recencyDwell = longDwell
        for session in sessions { store.removeFromRecency(session.id) }
        return (store, sessions)
    }

    @Test func walkingPastSessionsRecordsNoneOfThem() {
        let (store, sessions) = makeDwellStore()
        for session in sessions { store.selectSession(session.id) }
        #expect(store.sessionRecency.items.isEmpty)
    }

    @Test func theDwellElapsingRecordsTheSelection() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[1].id)
        store.recencyDwellDebouncer.flush()
        #expect(store.sessionRecency.items == [sessions[1].id])
    }

    @Test func onlyTheSessionStillSelectedWhenTheDwellElapsesIsRecorded() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[0].id)
        store.selectSession(sessions[2].id)
        store.recencyDwellDebouncer.flush()
        #expect(store.sessionRecency.items == [sessions[2].id])
    }

    @Test func aFireWhoseSessionIsNoLongerSelectedIsDropped() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[0].id)
        store.selectedSessionID = sessions[1].id // moved without re-arming, as a close reselection can
        store.recencyDwellDebouncer.flush()
        #expect(store.sessionRecency.items.isEmpty)
    }

    /// `reselectIfSelectionHidden` is the real caller that moves the selection while another id is armed:
    /// unflagging the active row in flagged mode pushes the selection elsewhere before the dwell elapses.
    @Test func unflaggingTheActiveRowDropsItsPendingPush() {
        let (store, sessions) = makeDwellStore()
        store.sidebarMode = .flagged
        store.setFlag(true, forSessions: [sessions[0].id, sessions[1].id])
        store.selectSession(sessions[0].id)
        store.setFlag(false, forSession: sessions[0].id)
        store.recencyDwellDebouncer.flush()
        #expect(store.selectedSessionID == sessions[1].id)
        #expect(store.sessionRecency.items == [sessions[1].id])
    }

    @Test func anImmediateDwellRecordsOnSelectionWithNoTimer() {
        let (store, sessions) = makeDwellStore()
        store.recencyDwell = nil
        store.selectSession(sessions[0].id)
        store.selectSession(sessions[1].id)
        #expect(store.sessionRecency.items == [sessions[1].id, sessions[0].id])
    }

    @Test func typingRecordsThePendingSessionWithoutWaitingOutTheDwell() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[0].id)
        store.noteUserActivity(typed: true)
        #expect(store.sessionRecency.items == [sessions[0].id])
    }

    @Test func aSelectionDoesNotServeTheDwell() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[0].id)
        store.noteUserActivity()
        #expect(store.sessionRecency.items.isEmpty)
    }

    @Test func typingWithNothingPendingRecordsNothing() {
        let (store, _) = makeDwellStore()
        store.noteUserActivity(typed: true)
        #expect(store.sessionRecency.items.isEmpty)
    }

    @Test func typingAfterTheDwellAlreadyFiredChangesNothing() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[0].id)
        store.recencyDwellDebouncer.flush()
        store.noteUserActivity(typed: true)
        #expect(store.sessionRecency.items == [sessions[0].id])
    }

    @Test func switchingToImmediateRecordsThePendingSelection() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[0].id)
        store.setRecencyDwell(nil)
        #expect(store.sessionRecency.items == [sessions[0].id])
    }

    @Test func settingTheSameDwellLeavesThePendingPushArmed() {
        let (store, sessions) = makeDwellStore()
        store.selectSession(sessions[0].id)
        store.setRecencyDwell(longDwell)
        #expect(store.sessionRecency.items.isEmpty)
        store.recencyDwellDebouncer.flush()
        #expect(store.sessionRecency.items == [sessions[0].id])
    }

    @Test func restoreRecordsTheSelectionWithoutServingTheDwell() {
        let store = makeStore()
        store.recencyDwell = longDwell
        let ids = [UUID(), UUID()]
        let sessions = ids.map { SessionSnapshot(id: $0, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: sessions)]))
        #expect(store.sessionRecency.items == [ids[1]])
    }
}
