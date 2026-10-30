import Foundation
import Testing
@testable import agtermCore

/// What a window store tells the library for the app-wide visit list: each id its recency pushes, and each id a
/// real close drops. The frontmost check is the library's; these cases pin only what the store reports.
@MainActor
struct AppStoreAppRecencyTests {
    private let longDwell: TimeInterval = 20

    /// Collects every id the two hooks report.
    private final class Hooks {
        var pushed: [UUID] = []
        var forgotten: [UUID] = []
    }

    /// Two workspaces, `home` with one session and `work` with three, the hooks wired after setup so the
    /// pushes `addSession` made on the way in are not counted. `dwell` nil records on selection.
    private func makeHookedStore(dwell: TimeInterval?) -> (AppStore, Hooks, (home: Workspace, work: Workspace)) {
        let store = makeStore()
        let home = store.addWorkspace(name: "home")
        _ = store.addSession(toWorkspace: home.id, cwd: "/home")
        let work = store.addWorkspace(name: "work")
        for cwd in ["/a", "/b", "/c"] { _ = store.addSession(toWorkspace: work.id, cwd: cwd) }
        store.recencyDwell = dwell
        let hooks = Hooks()
        store.onRecencyPush = { hooks.pushed.append($0) }
        store.onRecencyForget = { hooks.forgotten.append($0) }
        let current = { (id: UUID) in store.workspaces.first { $0.id == id } ?? Workspace(name: "missing") }
        return (store, hooks, (current(home.id), current(work.id)))
    }

    /// Empties the per-window list, so a case can tell a fresh push from an id that was already first.
    private func clearRecency(_ store: AppStore) {
        for id in store.sessionRecency.items { store.removeFromRecency(id) }
    }

    // MARK: - Push

    @Test func anImmediateSelectionReportsThePushOnce() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        store.selectSession(work.sessions[0].id)
        #expect(hooks.pushed == [work.sessions[0].id])
    }

    @Test func aDwellReportsNothingUntilItElapses() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: longDwell)
        store.selectSession(work.sessions[0].id)
        #expect(hooks.pushed.isEmpty)
        store.recencyDwellDebouncer.flush()
        #expect(hooks.pushed == [work.sessions[0].id])
    }

    @Test func recordRecencyNowReportsThePush() throws {
        let (store, hooks, (_, _)) = makeHookedStore(dwell: longDwell)
        let selected = try #require(store.selectedSessionID)
        store.recordRecencyNow()
        #expect(hooks.pushed == [selected])
    }

    @Test(arguments: [nil, 20.0] as [TimeInterval?])
    func restoreReportsNoPushWhileTheWindowListKeepsTheSelection(dwell: TimeInterval?) {
        let (store, hooks, (_, _)) = makeHookedStore(dwell: dwell)
        let ids = [UUID(), UUID()]
        let sessions = ids.map { SessionSnapshot(id: $0, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: sessions)]))
        store.recencyDwellDebouncer.flush()
        #expect(store.sessionRecency.items == [ids[1]])
        #expect(hooks.pushed.isEmpty)
    }

    // MARK: - Move fallback

    @Test(arguments: [nil, 20.0] as [TimeInterval?])
    func detachWorkspaceRecordsTheFallbackOnlyInTheWindowList(dwell: TimeInterval?) {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: dwell)
        store.selectSession(work.sessions[1].id)
        store.recencyDwellDebouncer.flush()
        clearRecency(store)
        hooks.pushed.removeAll()

        store.detachWorkspace(work.id)
        store.recencyDwellDebouncer.flush()

        let reselected = store.selectedSessionID
        #expect(reselected != nil)
        #expect(store.sessionRecency.items.first == reselected)
        #expect(hooks.pushed.isEmpty)
    }

    @Test(arguments: [nil, 20.0] as [TimeInterval?])
    func detachSessionsRecordsTheFallbackOnlyInTheWindowList(dwell: TimeInterval?) {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: dwell)
        store.selectSession(work.sessions[1].id)
        store.recencyDwellDebouncer.flush()
        clearRecency(store)
        hooks.pushed.removeAll()

        store.detachSessions([work.sessions[1].id])
        store.recencyDwellDebouncer.flush()

        let reselected = store.selectedSessionID
        #expect(reselected != nil && reselected != work.sessions[1].id)
        #expect(store.sessionRecency.items.first == reselected)
        #expect(hooks.pushed.isEmpty)
    }

    // MARK: - Close reselection

    @Test(arguments: [nil, 20.0] as [TimeInterval?])
    func closingTheActiveSessionReportsTheReselection(dwell: TimeInterval?) throws {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: dwell)
        store.selectSession(work.sessions[1].id)
        store.recencyDwellDebouncer.flush()
        hooks.pushed.removeAll()

        store.closeSession(work.sessions[1].id)
        store.recencyDwellDebouncer.flush()

        let reselected = try #require(store.selectedSessionID)
        #expect(reselected != work.sessions[1].id)
        #expect(hooks.pushed == [reselected])
    }

    @Test(arguments: [nil, 20.0] as [TimeInterval?])
    func removingTheActiveWorkspaceReportsTheReselection(dwell: TimeInterval?) {
        let (store, hooks, (home, work)) = makeHookedStore(dwell: dwell)
        store.selectSession(work.sessions[1].id)
        store.recencyDwellDebouncer.flush()
        hooks.pushed.removeAll()

        store.removeWorkspace(work.id)
        store.recencyDwellDebouncer.flush()

        #expect(store.selectedSessionID == home.sessions[0].id)
        #expect(hooks.pushed == [home.sessions[0].id])
    }

    // MARK: - Forget

    @Test func closeSessionReportsTheClosedID() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        store.closeSession(work.sessions[2].id)
        #expect(hooks.forgotten == [work.sessions[2].id])
    }

    @Test func removeWorkspaceReportsEveryRemovedID() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        store.removeWorkspace(work.id)
        #expect(hooks.forgotten == work.sessions.map(\.id))
    }

    @Test func theEndOfASoftCloseGraceReportsTheClosedID() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        #expect(store.softCloseSession(work.sessions[2].id, grace: 60))
        #expect(hooks.forgotten.isEmpty)
        store.finalizeAllPendingCloses()
        #expect(hooks.forgotten == [work.sessions[2].id])
    }

    @Test func theEndOfASoftWorkspaceCloseGraceReportsEveryRemovedID() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        #expect(store.softRemoveWorkspace(work.id, grace: 60))
        #expect(hooks.forgotten.isEmpty)
        store.finalizeAllPendingCloses()
        #expect(Set(hooks.forgotten) == Set(work.sessions.map(\.id)))
        #expect(hooks.forgotten.count == work.sessions.count)
    }

    @Test func anUndoneSoftCloseReportsNothing() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        #expect(store.softCloseSession(work.sessions[2].id, grace: 60))
        #expect(store.undoPendingClose())
        store.finalizeAllPendingCloses()
        #expect(hooks.forgotten.isEmpty)
    }

    // MARK: - Transfer never forgets

    @Test func detachWorkspaceDropsItsIDsWithoutReportingThem() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        for session in work.sessions { store.selectSession(session.id) }
        store.detachWorkspace(work.id)
        #expect(work.sessions.allSatisfy { !store.sessionRecency.items.contains($0.id) })
        #expect(hooks.forgotten.isEmpty)
    }

    @Test func detachSessionsDropsTheIDsWithoutReportingThem() {
        let (store, hooks, (_, work)) = makeHookedStore(dwell: nil)
        let leaving = [work.sessions[0].id, work.sessions[2].id]
        for id in leaving { store.selectSession(id) }
        store.detachSessions(leaving)
        #expect(leaving.allSatisfy { !store.sessionRecency.items.contains($0) })
        #expect(hooks.forgotten.isEmpty)
    }

    @Test func withdrawTransferredDropsTheIDsWithoutReportingThem() {
        let (store, hooks, (_, _)) = makeHookedStore(dwell: nil)
        let previous = store.selectedSessionID
        let moved = Session(initialCwd: "/moved")
        let workspace = Workspace(name: "moved", sessions: [moved])
        store.attachWorkspace(workspace, selecting: moved.id)
        #expect(store.sessionRecency.items.contains(moved.id))

        store.withdrawTransferred(sessionIDs: [moved.id], workspaceID: workspace.id, createdWorkspace: true,
                                  previousSelection: previous)

        #expect(!store.sessionRecency.items.contains(moved.id))
        #expect(hooks.forgotten.isEmpty)
    }
}
