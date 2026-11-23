import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreAttachedRestoreTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// snapshotWithBookRows also carries the terminal rows `RemoteRowBook` owns, so the snapshot's restore path is tested.
    private func snapshotWithBookRows(_ store: AppStore) -> Snapshot {
        var snapshot = store.snapshot()
        for index in snapshot.workspaces.indices {
            guard let workspace = store.workspaces.first(where: { $0.id == snapshot.workspaces[index].id }) else { continue }
            snapshot.workspaces[index].attached = store.attachedSnapshots(of: workspace, includingBookRows: true)
        }
        return snapshot
    }

    private func relaunched(_ store: AppStore, selecting selected: UUID? = nil) -> AppStore {
        var snapshot = snapshotWithBookRows(store)
        if let selected { snapshot.selectedSessionID = selected }
        let restored = makeStore()
        restored.restore(from: snapshot, launchRestore: true)
        return restored
    }

    @Test func aSnapshotKeepsAttachedRowsApartFromLocalSessions() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/first"))
        let row = try addAttachedRow(to: store, workspace: work.id)
        row.customName = "remote"
        row.flagged = true
        row.context = "deploy"
        let last = try #require(store.addSession(toWorkspace: work.id, cwd: "/last"))

        #expect(store.snapshot().workspaces.first?.attached == nil)
        let saved = try #require(snapshotWithBookRows(store).workspaces.first)
        #expect(saved.sessions.map(\.id) == [first.id, last.id])
        let attached = try #require(saved.attached?.first)
        #expect(saved.attached?.count == 1)
        #expect(attached.index == 1)
        #expect(attached.session.id == row.id)
        #expect(attached.session.cwd == home)
        #expect(attached.session.customName == "remote")
        #expect(attached.session.flagged == true)
        #expect(attached.session.context == "deploy")
        #expect(attached.session.initialCommand == nil)
        #expect(attached.session.restoreCommand == nil)
        #expect(attached.origin.host == "box")
        #expect(attached.origin.sessionID == "o1")
        #expect(attached.origin.endpoint == attachedEndpoint)
        #expect(attached.origin.panes.map(\.pane) == [row.paneIdentity])
        #expect(attached.origin.page == nil)
    }

    @Test func aRelaunchPutsAnAttachedRowBackInPlaceAttachingWithoutTheLead() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/first"))
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        let last = try #require(store.addSession(toWorkspace: work.id, cwd: "/last"))

        let restored = relaunched(store, selecting: row.id)

        #expect(restored.workspaces[0].sessions.map(\.id) == [first.id, row.id, last.id])
        let back = try #require(restored.session(withID: row.id))
        #expect(back.remoteHost == "box")
        #expect(back.remoteSessionID == "o1")
        #expect(back.remotePresentation?.binding == row.remotePresentation?.binding)
        #expect(back.awaitsOriginCheck)
        #expect(!back.ended)
        #expect(!back.asleep)
        #expect(back.commandWait)
        #expect(back.initialCommand != nil)
        #expect(back.initialCommand != RemoteSession.endedCommand(host: "box"))
        #expect(back.hasSplit)
        #expect(back.splitPaneIdentity == row.splitPaneIdentity)
        #expect(back.splitInitialCommand != nil)
        #expect(ZmxLeadBook.shared.states[back.paneIdentity]?.attachment.claim == false)
        #expect(ZmxLeadBook.shared.states[try #require(back.splitPaneIdentity)]?.attachment.claim == false)
    }

    @Test func aRelaunchedRowAttachesOnItsHostPoolWhenTheStoreHasOne() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        let split = try #require(row.splitPaneIdentity)
        let pools = SshHostPools(root: "/tmp/agterm-ssh-test", owner: "/state-\(UUID().uuidString)", runner: AnsweringRunner())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let pooled = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: nil, sshHostPools: pools)

        var snapshot = snapshotWithBookRows(store)
        snapshot.selectedSessionID = row.id
        pooled.restore(from: snapshot, launchRestore: true)

        let back = try #require(pooled.session(withID: row.id))
        let pool = pools.pool(for: "box")
        let left = try #require(back.initialCommand)
        let right = try #require(back.splitInitialCommand)
        #expect(left.contains("ControlPath=\(pool.lease("pane:\(row.paneIdentity)"))"), "\(left)")
        #expect(right.contains("ControlPath=\(pool.lease("pane:\(split)"))"), "\(right)")
        #expect(!left.contains("ControlPath=none"))
        #expect(pool.load == [2])
    }

    @Test func aRelaunchedRowKeepsItsOwnConnectionWithoutAHostPool() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id)

        let back = try #require(relaunched(store, selecting: row.id).session(withID: row.id))

        let line = try #require(back.initialCommand)
        #expect(line.contains("ControlPath=none"), "\(line)")
    }

    @Test func everyRestoredAttachedRowButTheFinalSelectionComesBackAsleep() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let asleep = try addAttachedRow(to: store, workspace: work.id, origin: "o1", split: true)
        let selected = try addAttachedRow(to: store, workspace: work.id, origin: "o2")
        let other = try addAttachedRow(to: store, workspace: work.id, origin: "o3")
        let pools = SshHostPools(root: "/tmp/agterm-ssh-test", owner: "/state-\(UUID().uuidString)", runner: AnsweringRunner())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let pooled = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: nil, sshHostPools: pools)

        var snapshot = snapshotWithBookRows(store)
        snapshot.selectedSessionID = selected.id
        pooled.restore(from: snapshot, launchRestore: true)

        for id in [asleep.id, other.id] {
            let back = try #require(pooled.session(withID: id))
            #expect(back.asleep)
            #expect(back.asleepSince != nil)
            #expect(back.initialCommand == nil)
            #expect(back.splitInitialCommand == nil)
            #expect(back.commandWait)
            #expect(ZmxLeadBook.shared.states[back.paneIdentity] == nil)
        }
        let split = try #require(pooled.session(withID: asleep.id)?.splitPaneIdentity)
        #expect(pooled.session(withID: asleep.id)?.splitCommandWait == true)
        #expect(ZmxLeadBook.shared.states[split] == nil)
        let woken = try #require(pooled.session(withID: selected.id))
        #expect(!woken.asleep)
        #expect(woken.asleepSince == nil)
        #expect(woken.offScreenSince == nil)
        #expect(woken.initialCommand?.contains("ControlPath=") == true)
        #expect(ZmxLeadBook.shared.states[woken.paneIdentity]?.attachment.claim == false)
        #expect(pools.pool(for: "box").load == [1], "only the woken row's pane leases")
        let window = LaunchSpawnWindow(selectedSessionID: pooled.selectedSessionID, sessions: pooled.workspaces.flatMap(\.sessions))
        let sleeping = [asleep.paneIdentity, split, other.paneIdentity]
        #expect(LaunchSpawnPlan.make(windows: [window]).order.allSatisfy { !sleeping.contains($0) })
        ZmxLeadBook.shared.forget(pane: woken.paneIdentity)
    }

    @Test func aSelectionMovedOffAHiddenRowWakesTheAttachedRowItLandsOn() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: work.id, cwd: "/local"))
        let row = try addAttachedRow(to: store, workspace: work.id)
        row.flagged = true
        var snapshot = snapshotWithBookRows(store)
        snapshot.selectedSessionID = local.id
        snapshot.sidebarMode = .flagged

        let restored = makeStore()
        restored.restore(from: snapshot, launchRestore: true)

        #expect(restored.selectedSessionID == row.id)
        let back = try #require(restored.session(withID: row.id))
        #expect(!back.asleep)
        #expect(back.initialCommand != nil)
        #expect(back.initialCommand != RemoteSession.endedCommand(host: "box"))
        ZmxLeadBook.shared.forget(pane: back.paneIdentity)
    }

    @Test func aRestoredSelectionWhoseDaemonIsGoneWakesOnTheEndedLine() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id)
        var snapshot = snapshotWithBookRows(store)
        snapshot.selectedSessionID = row.id
        snapshot.workspaces[0].attached?[0].origin.panes.removeAll()

        let restored = makeStore()
        restored.restore(from: snapshot, launchRestore: true)

        let back = try #require(restored.session(withID: row.id))
        #expect(restored.selectedSessionID == row.id)
        #expect(!back.asleep)
        #expect(back.initialCommand == RemoteSession.endedCommand(host: "box"))
    }

    @Test func aRelaunchReclaimsTheLeadOnlyWhereThePaneLedWhenSaved() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        let split = try #require(row.splitPaneIdentity)
        let led = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(led, pane: row.paneIdentity)
        _ = ZmxLeadBook.shared.apply(try #require(ZmxLeadNotice(title: "zmx-role;\(led.nonce):leader:1")), pane: row.paneIdentity)
        let followed = ZmxLeadAttachment(claim: true)
        ZmxLeadBook.shared.begin(followed, pane: split)
        _ = ZmxLeadBook.shared.apply(try #require(ZmxLeadNotice(title: "zmx-role;\(followed.nonce):follower:1")), pane: split)

        let restored = relaunched(store)

        let back = try #require(restored.session(withID: row.id))
        let primary = try #require(ZmxLeadBook.shared.states[back.paneIdentity]?.attachment)
        #expect(!primary.claim)
        #expect(primary.reclaim == led.nonce)
        #expect(back.initialCommand?.contains("\(ZmxLeadAttachment.reclaimVariable)=\(led.nonce)") == true)
        let right = try #require(ZmxLeadBook.shared.states[split]?.attachment)
        #expect(!right.claim)
        #expect(right.reclaim == nil)
        #expect(back.splitInitialCommand?.contains(ZmxLeadAttachment.reclaimVariable) == false)
    }

    @Test func closingARowEndsItsPanesWaitToReconnectSoNoOldLeadIsSaved() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        let split = try #require(row.splitPaneIdentity)
        for pane in [row.paneIdentity, split] {
            RemoteReconnectBook.shared.wait(pane: pane, session: row.id, host: "box", cover: true, reclaim: "n1", now: Date())
        }

        store.closeSession(row.id)

        #expect(!RemoteReconnectBook.shared.waiting(pane: row.paneIdentity))
        #expect(!RemoteReconnectBook.shared.waiting(pane: split))
        #expect(ZmxLeadBook.shared.savedLead(pane: row.paneIdentity) == nil)
    }

    @Test func aSplitWhoseDaemonIsNotInTheBindingIsDropped() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        var snapshot = snapshotWithBookRows(store)
        snapshot.workspaces[0].attached?[0].origin.panes.removeAll { $0.pane == row.splitPaneIdentity }

        let restored = makeStore()
        restored.restore(from: snapshot, launchRestore: true)

        let back = try #require(restored.session(withID: row.id))
        #expect(!back.hasSplit)
        #expect(back.splitPaneIdentity == nil)
        #expect(back.splitInitialCommand == nil)
    }

    @Test func aRowSavedEndedIsNotRestoredAndItsCompanionComesBackOnItsOwn() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, origin: "o1")
        let companion = try addAttachedRow(to: store, workspace: work.id, origin: "o2")
        companion.parentID = row.id
        row.ended = true

        let restored = relaunched(store)

        #expect(restored.session(withID: row.id) == nil)
        let back = try #require(restored.session(withID: companion.id))
        #expect(back.parentID == nil)
        #expect(back.awaitsOriginCheck)
    }

    @Test func aHeadlessRowThatLostItsDaemonStillRestoresEnded() throws {
        let (store, session) = makeHeadlessSession(split: false)
        store.markSessionEnded(session.id)

        let restored = makeStore()
        restored.restore(from: store.snapshot(), launchRestore: true)

        #expect(restored.session(withID: session.id)?.ended == true)
    }

    @Test func aPageRowRestoresWaitingForItsPage() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, page: true)
        #expect(store.snapshot().workspaces[0].attached?.first?.origin.page == true)

        let back = try #require(relaunched(store).session(withID: row.id))

        #expect(back.content == .page)
        #expect(!back.overlayActive)
        #expect(back.initialCommand == nil)
        #expect(back.awaitsOriginCheck)
        #expect(back.remotePresentation?.connection == .connecting)
        #expect(!back.asleep)
    }

    @Test func anAttachedGroupWithAPageCompanionComesBackGrouped() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let parent = try addAttachedRow(to: store, workspace: work.id, origin: "o1")
        let page = try addAttachedRow(to: store, workspace: work.id, origin: "o2", page: true)
        page.parentID = parent.id
        let after = try #require(store.addSession(toWorkspace: work.id, cwd: "/after"))

        let restored = relaunched(store)

        #expect(restored.workspaces[0].sessions.map(\.id) == [parent.id, page.id, after.id])
        #expect(restored.session(withID: page.id)?.parentID == parent.id)
        #expect(restored.session(withID: page.id)?.content == .page)
        #expect(restored.companions(of: parent.id).map(\.id) == [page.id])
    }

    @Test func anAttachedPageRowIsOnDiskOnceItIsBoundAndATerminalRowIsLeftToTheBook() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-attached-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(persistence: PersistenceStore(directory: directory))
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id)
        let page = try addAttachedRow(to: store, workspace: work.id, origin: "o2", page: true)

        let saved = PersistenceStore(directory: directory).load().workspaces.flatMap { $0.attached ?? [] }

        #expect(saved.map(\.session.id) == [page.id])
        #expect(RemoteRowBook.Record.covers(row))
    }

    @Test func aServerWindowRowIsNotSaved() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, catalogOwned: true)

        let saved = try #require(store.snapshot().workspaces.first)

        #expect(saved.attached == nil)
        #expect(!saved.sessions.contains { $0.id == row.id })
    }

    @Test func closingAnEndedAttachedRowLeavesItsCompanionAndNoRecentClosedEntry() throws {
        let (store, recent, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, origin: "o1", split: true)
        let companion = try addAttachedRow(to: store, workspace: work.id, origin: "o2")
        companion.parentID = row.id

        store.closeEndedAttachedRow(row.id)

        #expect(store.session(withID: row.id) == nil)
        #expect(store.session(withID: companion.id)?.parentID == nil)
        #expect(recent.loadRemote().isEmpty)
        store.closeSession(companion.id)
        #expect(recent.loadRemote().count == 1)
    }

    @Test func closingALocalRowAsEndedDoesNothing() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))

        store.closeEndedAttachedRow(local.id)

        #expect(store.session(withID: local.id) != nil)
    }

    @Test func aRelaunchKeepsTheFollowedCompanionsAndTellsAnEmptyBaselineFromNone() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let followed = try addAttachedRow(to: store, workspace: work.id)
        let empty = try addAttachedRow(to: store, workspace: work.id, origin: "o2")
        let unbaselined = try addAttachedRow(to: store, workspace: work.id, origin: "o3")
        let child = UUID()
        store.baselineCompanions([child.uuidString], forSession: followed.id)
        store.baselineCompanions([], forSession: empty.id)

        let restored = relaunched(store)

        let back = try #require(restored.session(withID: followed.id))
        #expect(back.companionsBaselined)
        #expect(back.followedCompanions == [child.uuidString])
        #expect(try #require(restored.session(withID: empty.id)).companionsBaselined)
        #expect(try #require(restored.session(withID: empty.id)).followedCompanions.isEmpty)
        #expect(try #require(restored.session(withID: unbaselined.id)).companionsBaselined == false)
    }

    @Test func aRowSavedWithoutTheFollowKeysRestoresEmptyAndNotBaselined() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id)
        store.baselineCompanions([UUID().uuidString], forSession: row.id)
        var snapshot = store.snapshot()
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.workspaces[0])) as? [String: Any])
        var attached = try #require(object["attached"] as? [[String: Any]])
        #expect(attached[0]["followedCompanions"] != nil)
        attached[0]["followedCompanions"] = nil
        attached[0]["companionsBaselined"] = nil
        object["attached"] = attached
        snapshot.workspaces[0] = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        let restored = makeStore()
        restored.restore(from: snapshot, launchRestore: true)

        let back = try #require(restored.session(withID: row.id))
        #expect(back.followedCompanions.isEmpty)
        #expect(!back.companionsBaselined)
    }

    @Test func aBuildThatPredatesAttachedRowsReadsOnlyTheLocalSessions() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try addAttachedRow(to: store, workspace: work.id)
        let data = try JSONEncoder().encode(store.snapshot().workspaces[0])

        let legacy = try JSONDecoder().decode(LegacyWorkspace.self, from: data)

        #expect(legacy.sessions.map(\.id) == [local.id])
    }

    @Test func aFileWithoutAttachedRowsOrWithAnUnreadableListStillRestoresItsSessions() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try addAttachedRow(to: store, workspace: work.id)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.snapshot().workspaces[0]))
            as? [String: Any])

        object["attached"] = nil
        let old = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        object["attached"] = "garbage"
        let broken = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(old.attached == nil)
        #expect(old.sessions.map(\.id) == [local.id])
        #expect(broken.attached == nil)
        #expect(broken.sessions.map(\.id) == [local.id])
    }
}

private struct LegacyWorkspace: Decodable {
    let id: UUID
    let name: String
    let sessions: [SessionSnapshot]
}
