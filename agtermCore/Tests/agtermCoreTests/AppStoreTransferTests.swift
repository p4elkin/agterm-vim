import Foundation
import Testing
@testable import agtermCore

@MainActor
final class AppStoreTransferTests {
    private let directory: URL
    private var events: [ControlEventDraft] = []
    private var finalized: [[UUID]] = []
    private var dropped: [[UUID]] = []

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-transfer-\(UUID().uuidString)")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - releaseForTransfer

    @Test func releasePreparesBothPanesAndEmptiesEverySlot() {
        let session = Session(initialCwd: "/tmp", splitPaneIdentity: UUID())
        let identities = (session.paneIdentity, session.splitPaneIdentity)
        let primary = TransferSpySurface(backedByZmx: true)
        let split = TransferSpySurface(backedByZmx: true)
        let scratch = TransferSpySurface()
        let paneOverlay = TransferSpySurface()
        session.surface = primary
        session.splitSurface = split
        session.hasSplit = true
        session.scratchSurface = scratch
        session.scratchActive = true
        session.setPaneOverlay(PaneOverlay(command: "revdiff", wait: false), pane: .left)
        session.setPaneOverlaySurface(paneOverlay, pane: .left)
        session.parkedRebased = ParkedRebased(overlay: RebasedOverlay(project: "/tmp/repo"), sizePercent: nil)
        session.searchActive = true
        session.searchSurface = primary
        let store = makeStore([Workspace(name: "work", sessions: [session])], selected: session.id)
        #expect(store.openOverlay(session.id, command: "htop"))
        let overlay = TransferSpySurface()
        session.overlaySurface = overlay

        store.releaseForTransfer([session.id])

        #expect(primary.prepareCount == 1 && split.prepareCount == 1)
        #expect(primary.teardownCount == 0 && split.teardownCount == 0)
        #expect(scratch.teardownCount == 1 && overlay.teardownCount == 1 && paneOverlay.teardownCount == 1)
        #expect(!session.overlayActive)
        #expect(!session.scratchActive)
        #expect(session.hudSpec == nil)
        #expect(!session.searchActive)
        #expect(session.parkedRebased == nil)
        #expect(session.paneOverlay(.left) == nil)
        #expect(session.surface == nil && session.splitSurface == nil && session.scratchSurface == nil)
        #expect(session.overlaySurface == nil && session.searchSurface == nil)
        #expect(session.paneOverlaySurface(.left) == nil && session.paneOverlaySurface(.right) == nil)
        #expect(session.paneIdentity == identities.0 && session.splitPaneIdentity == identities.1)
        #expect(finalized.isEmpty)
        #expect(store.session(withID: session.id) === session)
        #expect(writtenFiles().isEmpty)
    }

    @Test func releaseClearsAShownScratchWhoseSurfaceNeverRealized() {
        let session = Session(initialCwd: "/tmp")
        session.scratchActive = true
        let store = makeStore([Workspace(name: "work", sessions: [session])], selected: session.id)

        store.releaseForTransfer([session.id])

        #expect(!session.scratchActive)
    }

    @Test func releaseDiscardsAHud() {
        let session = Session(initialCwd: "/tmp")
        let store = makeStore([Workspace(name: "work", sessions: [session])], selected: session.id)
        #expect(store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"),
                              file: directory.appendingPathComponent("hud").path,
                              size: HudPanelSize(widthPercent: 30, heightPercent: 9)))
        session.overlaySurface = TransferSpySurface()

        store.releaseForTransfer([session.id])

        #expect(session.hudSpec == nil)
        #expect(!session.overlayActive)
        #expect(session.overlaySurface == nil)
        #expect(finalized.isEmpty)
    }

    // MARK: - attach

    @Test func attachWorkspaceAppendsAndSelects() {
        let (store, home) = destination()
        let moved = Session(initialCwd: "/moved")
        let other = Session(initialCwd: "/other")
        let workspace = Workspace(name: "moved", sessions: [other, moved])

        store.attachWorkspace(workspace, selecting: moved.id)

        #expect(store.workspaces.map(\.id) == [home.id, workspace.id])
        #expect(store.selectedSessionID == moved.id)
        #expect(store.sidebarSelectionIDs == [moved.id])
        #expect(store.sessionRecency.items.first == moved.id)
        #expect(kinds().contains(.treeChanged))
        #expect(!kinds().contains(.sessionCreated))
        #expect(writtenFiles().isEmpty)
    }

    @Test func attachWorkspaceIntoAFilteredWindowMarksItAndKeepsTheFilter() {
        let (store, home) = destination()
        store.focusedWorkspaceIDs = [home.id]
        store.focusEnabled = true
        let moved = Session(initialCwd: "/moved")
        let workspace = Workspace(name: "moved", sessions: [moved])

        store.attachWorkspace(workspace, selecting: moved.id)

        #expect(store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [home.id, workspace.id])
    }

    @Test func withdrawOfACreatedWorkspaceLeavesNoFocusMember() {
        let (store, home) = destination()
        store.focusedWorkspaceIDs = [home.id]
        store.focusEnabled = true
        let previous = store.selectedSessionID
        let moved = Session(initialCwd: "/moved")
        let workspace = Workspace(name: "moved", sessions: [moved])
        store.attachWorkspace(workspace, selecting: moved.id)

        store.withdrawTransferred(sessionIDs: [moved.id], workspaceID: workspace.id, createdWorkspace: true,
                                  previousSelection: previous)

        #expect(store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [home.id])
    }

    @Test func attachWorkspaceWithoutSelectionKeepsTheCurrentOne() {
        let (store, home) = destination()
        let before = store.selectedSessionID
        let workspace = Workspace(name: "moved", sessions: [Session(initialCwd: "/moved")])

        store.attachWorkspace(workspace, selecting: nil)

        #expect(store.workspaces.map(\.id) == [home.id, workspace.id])
        #expect(store.selectedSessionID == before)
        #expect(!kinds().contains(.sessionSelected))
    }

    @Test func attachSessionsAppendsToAnExistingWorkspaceAndSelectsTheFirst() {
        let (store, home) = destination()
        let existing = home.sessions.map(\.id)
        let first = Session(initialCwd: "/a")
        let second = Session(initialCwd: "/b")

        store.attachSessions([first, second], toWorkspace: home.id)

        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].sessions.map(\.id) == existing + [first.id, second.id])
        #expect(store.selectedSessionID == first.id)
        #expect(kinds().contains(.treeChanged))
        #expect(!kinds().contains(.sessionCreated))
        #expect(writtenFiles().isEmpty)
    }

    @Test func attachSessionsToANewWorkspaceCreatesExactlyOne() {
        let (store, home) = destination()
        let moved = Session(initialCwd: "/a")

        let id = store.attachSessions([moved], toNewWorkspaceNamed: "landing")

        #expect(store.workspaces.map(\.id) == [home.id, id])
        #expect(store.workspaces[1].name == "landing")
        #expect(store.workspaces[1].sessions.map(\.id) == [moved.id])
        #expect(store.selectedSessionID == moved.id)
        #expect(kinds().contains(.treeChanged))
        #expect(!kinds().contains(.sessionCreated))
        #expect(writtenFiles().isEmpty)
    }

    // MARK: - withdrawTransferred

    @Test func withdrawAfterAWorkspaceAttachRestoresTreeAndSelection() {
        let (store, _) = destination()
        let tree = shape(store)
        let previous = store.selectedSessionID
        let moved = Session(initialCwd: "/moved")
        let workspace = Workspace(name: "moved", sessions: [moved])
        store.attachWorkspace(workspace, selecting: moved.id)
        events.removeAll()

        store.withdrawTransferred(sessionIDs: [moved.id], workspaceID: workspace.id, createdWorkspace: true,
                                  previousSelection: previous)

        #expect(shape(store) == tree)
        #expect(store.selectedSessionID == previous)
        #expect(store.sessionRecency.items.first == previous)
        #expect(!store.sessionRecency.items.contains(moved.id))
        let selected = events.filter { $0.kind == .sessionSelected }
        #expect(selected.map(\.session) == [previous?.uuidString])
        #expect(!kinds().contains(.sessionCreated) && !kinds().contains(.sessionClosed))
        #expect(recentClosed().isEmpty)
        #expect(finalized.isEmpty && dropped.isEmpty)
        #expect(writtenFiles().isEmpty)
    }

    @Test func withdrawAfterASessionAttachKeepsTheExistingWorkspace() {
        let (store, home) = destination()
        let tree = shape(store)
        let previous = store.selectedSessionID
        let moved = [Session(initialCwd: "/a"), Session(initialCwd: "/b")]
        store.attachSessions(moved, toWorkspace: home.id)

        store.withdrawTransferred(sessionIDs: moved.map(\.id), workspaceID: home.id, createdWorkspace: false,
                                  previousSelection: previous)

        #expect(shape(store) == tree)
        #expect(store.selectedSessionID == previous)
        #expect(!kinds().contains(.sessionCreated) && !kinds().contains(.sessionClosed))
        #expect(recentClosed().isEmpty)
    }

    @Test func withdrawRemovesAWorkspaceTheTransferCreated() {
        let (store, _) = destination()
        let tree = shape(store)
        let previous = store.selectedSessionID
        let moved = Session(initialCwd: "/a")
        let created = store.attachSessions([moved], toNewWorkspaceNamed: "landing")
        events.removeAll()

        store.withdrawTransferred(sessionIDs: [moved.id], workspaceID: created, createdWorkspace: true,
                                  previousSelection: previous)

        #expect(shape(store) == tree)
        #expect(store.selectedSessionID == previous)
        #expect(events.filter { $0.kind == .sessionSelected }.map(\.session) == [previous?.uuidString])
        #expect(recentClosed().isEmpty)
        #expect(writtenFiles().isEmpty)
    }

    // MARK: - detach

    @Test func detachWorkspaceDropsItWithoutClosingAnything() {
        let (store, keep, leaving) = source()
        let active = leaving.sessions[0]
        active.openAsk(PendingAsk(id: UUID().uuidString, title: "Choose",
                                  buttons: [ControlAskButton(id: "ok", label: "OK")]))
        select(store, keep.sessions[0].id)
        select(store, active.id)
        store.focusedWorkspaceIDs = [leaving.id, keep.id]
        store.parkedRevealedWorkspaceIDs = [leaving.id, keep.id]
        events.removeAll()

        store.detachWorkspace(leaving.id)

        #expect(store.workspaces.map(\.id) == [keep.id])
        #expect(active.askPending == nil)
        #expect(store.selectedSessionID == keep.sessions[0].id)
        #expect(store.sidebarSelectionIDs == [keep.sessions[0].id])
        #expect(!store.focusedWorkspaceIDs.contains(leaving.id))
        #expect(store.parkedRevealedWorkspaceIDs == [keep.id])
        #expect(!leaving.sessions.contains { store.sessionRecency.items.contains($0.id) })
        #expect(kinds().contains(.treeChanged))
        #expect(!kinds().contains(.sessionClosed))
        #expect(finalized.isEmpty && dropped.isEmpty)
        #expect(recentClosed().isEmpty)
        #expect(writtenFiles().isEmpty)
    }

    @Test func detachWorkspaceForgetsItAsTheFreshWorkspace() {
        let (store, keep, _) = source()
        let empty = Workspace(name: "empty")
        store.workspaces.append(empty)
        select(store, keep.sessions[0].id)
        store.selectWorkspace(empty.id)
        #expect(store.currentWorkspaceID == empty.id)

        store.detachWorkspace(empty.id)
        store.attachWorkspace(empty, selecting: nil)

        #expect(store.currentWorkspaceID == keep.id)
    }

    @Test func detachWorkspaceDropsTheLastFocusMemberAndTheFilter() {
        let (store, _, leaving) = source()
        store.focusedWorkspaceIDs = [leaving.id]
        store.focusEnabled = true

        store.detachWorkspace(leaving.id)

        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)
    }

    @Test func detachSessionsMovesTheSelectionOffAndKeepsTheirPanes() {
        let (store, keep, leaving) = source()
        let stay = leaving.sessions[0]
        let moving = leaving.sessions[1]
        let alsoMoving = keep.sessions[0]
        moving.openAsk(PendingAsk(id: UUID().uuidString, title: "Choose",
                                  buttons: [ControlAskButton(id: "ok", label: "OK")]))
        select(store, stay.id)
        select(store, moving.id)
        events.removeAll()

        store.detachSessions([moving.id, alsoMoving.id])

        #expect(store.workspaces.map { $0.sessions.map(\.id) } == [[], [stay.id]])
        #expect(moving.askPending == nil)
        #expect(store.selectedSessionID == stay.id)
        #expect(store.sidebarSelectionIDs == [stay.id])
        #expect(!store.sessionRecency.items.contains(moving.id))
        #expect(!store.sessionRecency.items.contains(alsoMoving.id))
        #expect(kinds().contains(.treeChanged))
        #expect(!kinds().contains(.sessionClosed))
        #expect(finalized.isEmpty && dropped.isEmpty)
        #expect(recentClosed().isEmpty)
        #expect(writtenFiles().isEmpty)
    }

    @Test func detachSessionsLeavesAnInactiveSelectionAlone() {
        let (store, keep, leaving) = source()
        select(store, keep.sessions[0].id)
        events.removeAll()

        store.detachSessions([leaving.sessions[1].id])

        #expect(store.selectedSessionID == keep.sessions[0].id)
        #expect(!kinds().contains(.sessionSelected))
        #expect(store.workspaces[1].sessions.map(\.id) == [leaving.sessions[0].id])
    }

    // MARK: - refusals

    @Test func theLastWorkspaceIsRefused() {
        let only = Workspace(name: "only", sessions: [Session(initialCwd: "/tmp")])
        let store = makeStore([only], selected: nil)

        #expect(store.workspaceTransferRefusal(only.id) == "last workspace in window")
    }

    @Test func aWorkspaceNamedByAPendingCloseIsRefused() {
        let (store, keep, leaving) = source()
        #expect(store.workspaceTransferRefusal(leaving.id) == nil)

        #expect(store.softCloseSession(leaving.sessions[0].id, grace: 3600))

        #expect(store.workspaceTransferRefusal(leaving.id) == "workspace has a pending close")
        #expect(store.workspaceTransferRefusal(keep.id) == nil)
    }

    // MARK: - fixtures

    private func makeStore(_ workspaces: [Workspace], selected: UUID?) -> AppStore {
        AppStore(workspaces: workspaces, selectedSessionID: selected,
                 persistence: PersistenceStore(directory: directory),
                 recentClosedStore: RecentClosedStore(directory: directory),
                 controlEventSink: { [weak self] in self?.events.append($0) },
                 paneFinalizer: { [weak self] in self?.finalized.append($0) },
                 launchPaneDrop: { [weak self] in self?.dropped.append($0) })
    }

    private func destination() -> (AppStore, Workspace) {
        let home = Workspace(name: "home", sessions: [Session(initialCwd: "/home"), Session(initialCwd: "/src")])
        let store = makeStore([home], selected: home.sessions[1].id)
        store.recordRecencyNow()
        return (store, home)
    }

    private func source() -> (AppStore, Workspace, Workspace) {
        let keep = Workspace(name: "keep", sessions: [Session(initialCwd: "/keep")])
        let leaving = Workspace(name: "leaving", sessions: [Session(initialCwd: "/a"), Session(initialCwd: "/b")])
        return (makeStore([keep, leaving], selected: nil), keep, leaving)
    }

    private func select(_ store: AppStore, _ id: UUID) {
        store.selectedSessionID = id
        store.replaceSidebarSelection(with: id)
        store.recordRecencyNow()
    }

    private func shape(_ store: AppStore) -> [[UUID]] {
        store.workspaces.map { [$0.id] + $0.sessions.map(\.id) }
    }

    private func kinds() -> [ControlEventKind] {
        events.map(\.kind)
    }

    private func recentClosed() -> [RecentClosedItem] {
        RecentClosedStore(directory: directory).load()
    }

    private func writtenFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}

private final class TransferSpySurface: TerminalSurface {
    let paneToken = ""
    let isRealized = true
    let backedByZmx: Bool
    var teardownCount = 0
    var prepareCount = 0
    init(backedByZmx: Bool = false) { self.backedByZmx = backedByZmx }
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() {}
    func prepareForTransfer() { prepareCount += 1 }
}
