import Foundation
import Testing
@testable import agtermCore

@MainActor
final class AppStoreRemoteSleepTests {
    private let directory: URL
    private var events: [ControlEventDraft] = []
    private var panes: [UUID] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-remote-sleep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(onRowWake: (() -> ((Session) -> Void)?)? = nil) -> AppStore {
        AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent(UUID().uuidString)),
                 controlEventSink: { [weak self] in self?.events.append($0) }, paneFinalizer: nil, onRowWake: onRowWake)
    }

    private func remoteRow(in store: AppStore, split: Bool = false) throws -> Session {
        let workspace = store.workspaces.first ?? store.addWorkspace(name: "work")
        let row = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/srv", remoteHost: "box"))
        if split {
            row.hasSplit = true
            row.isSplit = true
            row.splitPaneIdentity = UUID()
        }
        panes += [row.paneIdentity] + (row.splitPaneIdentity.map { [$0] } ?? [])
        return row
    }

    private func forgetPanes() {
        panes.forEach { ZmxLeadBook.shared.forget(pane: $0) }
    }

    private func kinds(_ kind: ControlEventKind) -> [ControlEventDraft] {
        events.filter { $0.kind == kind }
    }

    @Test func sleepReleasesBothPanesAndForgetsTheirLeads() throws {
        defer { forgetPanes() }
        let store = makeStore()
        let row = try remoteRow(in: store, split: true)
        let split = try #require(row.splitPaneIdentity)
        let left = SleepSpySurface()
        let right = SleepSpySurface()
        row.surface = left
        row.splitSurface = right
        row.searchActive = true
        row.searchNeedle = "err"
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(claim: false), pane: row.paneIdentity)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(claim: false), pane: split)
        let now = Date(timeIntervalSince1970: 1_000)

        let respawns = row.primaryRespawns
        #expect(store.sleepRemoteRow(row.id, reason: .timer, now: now))

        #expect(left.sleepCount == 1)
        #expect(right.sleepCount == 1)
        #expect(left.prepareCount + left.teardownCount + right.prepareCount + right.teardownCount == 0)
        #expect(row.primaryRespawns == respawns &+ 1)
        #expect(row.surface == nil)
        #expect(row.splitSurface == nil)
        #expect(!row.searchActive)
        #expect(row.searchNeedle.isEmpty)
        #expect(ZmxLeadBook.shared.states[row.paneIdentity] == nil)
        #expect(ZmxLeadBook.shared.states[split] == nil)
        #expect(row.asleep)
        #expect(row.asleepSince == now)
        let slept = kinds(.sessionSlept)
        #expect(slept.count == 1)
        #expect(slept.first?.session == row.id.uuidString)
        #expect(slept.first?.payload.reason == "timer")
    }

    @Test func sleepKeepsTheHudAndAHiddenScratch() throws {
        let store = makeStore()
        let row = try remoteRow(in: store)
        let hud = SleepSpySurface()
        let scratch = SleepSpySurface()
        row.overlayActive = true
        row.hudSpec = HudSpec(message: "deploying")
        row.overlaySurface = hud
        row.scratchSurface = scratch

        #expect(store.sleepRemoteRow(row.id, reason: .command))

        #expect(row.overlaySurface === hud)
        #expect(row.scratchSurface === scratch)
        #expect([hud, scratch].allSatisfy { $0.sleepCount + $0.prepareCount + $0.teardownCount == 0 })
        #expect(row.overlayActive)
    }

    @Test func sleepIsRefusedForARowThatIsNotEligible() throws {
        let store = makeStore()
        let local = try #require(store.addSession(toWorkspace: store.addWorkspace(name: "work").id, cwd: "/repo"))
        let busy = try remoteRow(in: store)
        busy.scratchActive = true
        let surface = SleepSpySurface()
        busy.surface = surface

        #expect(!store.sleepRemoteRow(local.id, reason: .command))
        #expect(!store.sleepRemoteRow(busy.id, reason: .command))
        #expect(!store.sleepRemoteRow(UUID(), reason: .command))

        #expect(!local.asleep)
        #expect(!busy.asleep)
        #expect(busy.surface === surface)
        #expect(surface.sleepCount + surface.prepareCount == 0)
        #expect(kinds(.sessionSlept).isEmpty)
    }

    @Test func sleepingAnAsleepRowEmitsNothing() throws {
        let store = makeStore()
        let row = try remoteRow(in: store)
        let first = Date(timeIntervalSince1970: 10)
        #expect(store.sleepRemoteRow(row.id, reason: .timer, now: first))

        #expect(store.sleepRemoteRow(row.id, reason: .command, now: Date(timeIntervalSince1970: 20)))

        #expect(kinds(.sessionSlept).count == 1)
        #expect(row.asleepSince == first)
    }

    @Test func eachSleepAndWakeEdgeSchedulesOneTreeChangeAndNoOpsScheduleNone() throws {
        var renew = false
        let store = makeStore(onRowWake: { renew ? { _ in } : nil })
        let row = try remoteRow(in: store)
        let local = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/repo"))
        events.removeAll()

        #expect(store.sleepRemoteRow(row.id, reason: .timer))
        #expect(kinds(.treeChanged).count == 1)
        #expect(store.sleepRemoteRow(row.id, reason: .command))
        #expect(!store.sleepRemoteRow(local.id, reason: .command))
        #expect(!store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        #expect(kinds(.treeChanged).count == 1)

        renew = true
        #expect(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        #expect(kinds(.treeChanged).count == 2)
        #expect(store.wakeRemoteRow(row.id, reason: .command, onScreen: true))
        #expect(kinds(.treeChanged).count == 2)
    }

    @Test func aHiddenSplitWithFocusStaysTheFocusedPaneUntilItsSurfaceIsBuiltAgain() throws {
        defer { forgetPanes() }
        let store = makeStore(onRowWake: { { _ in } })
        let row = try remoteRow(in: store, split: true)
        row.isSplit = false
        row.splitFocused = true
        row.splitCwd = "/var/log"
        row.surface = SleepSpySurface()
        row.splitSurface = SleepSpySurface()
        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        #expect(row.rightPaneExists)
        #expect(row.focusedPane == .right)
        #expect(row.rendersPane(.right))
        #expect(!row.rendersPane(.left))
        #expect(row.focusedCwd == "/var/log")
        #expect(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        #expect(row.focusedPane == .right)
        row.surface = SleepSpySurface()
        #expect(row.activeSurface == nil, "the hidden primary is not the pane on screen")
        let rebuilt = SleepSpySurface()
        row.splitSurface = rebuilt
        row.splitSurface = nil
        #expect(!row.rightPaneExists, "a split surface built again ends the mark")
    }

    @Test func aSleepDoesNotMarkASplitThatHadNoSurface() throws {
        defer { forgetPanes() }
        let store = makeStore(onRowWake: { { _ in } })
        let row = try remoteRow(in: store, split: true)
        row.isSplit = false
        row.splitFocused = true
        row.surface = SleepSpySurface()

        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        #expect(!row.rightPaneExists)
        #expect(row.focusedPane == .left)
    }

    @Test func aSecondSleepBeforeTheSplitIsBuiltAgainKeepsTheMark() throws {
        defer { forgetPanes() }
        let store = makeStore(onRowWake: { { _ in } })
        let row = try remoteRow(in: store, split: true)
        row.isSplit = false
        row.splitFocused = true
        row.surface = SleepSpySurface()
        row.splitSurface = SleepSpySurface()
        #expect(store.sleepRemoteRow(row.id, reason: .timer))
        #expect(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        row.surface = SleepSpySurface()

        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        #expect(row.rightPaneExists)
        #expect(row.focusedPane == .right)
    }

    @Test(arguments: [false, true])
    func aSplitClosedOrPromotedWhileMarkedEndsTheMark(promote: Bool) throws {
        defer { forgetPanes() }
        let store = makeStore(onRowWake: { { _ in } })
        let row = try remoteRow(in: store, split: true)
        let split = try #require(row.splitPaneIdentity)
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [
            row.paneIdentity: ZmxSupport.daemonName(for: UUID()), split: ZmxSupport.daemonName(for: UUID()),
        ], presentationVersion: 1), forSession: row.id)
        row.surface = SleepSpySurface()
        row.splitSurface = SleepSpySurface()
        #expect(store.sleepRemoteRow(row.id, reason: .timer))
        #expect(row.rightPaneExists)

        if promote { _ = store.closePrimaryPane(row.id) } else { store.closeSplit(row.id) }
        #expect(!row.hasSplit)
        row.hasSplit = true
        row.splitPaneIdentity = UUID()
        row.splitFocused = true

        #expect(!row.rightPaneExists)
    }

    @Test func wakeClearsSleepRenewsTheRowAndEmits() throws {
        var renewed: [UUID] = []
        var asleepWhenRenewed: Bool?
        let store = makeStore(onRowWake: { { row in
            renewed.append(row.id)
            asleepWhenRenewed = row.asleep
            row.initialCommand = "renewed"
        } })
        let row = try remoteRow(in: store)
        row.offScreenSince = Date(timeIntervalSince1970: 5)
        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        #expect(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        #expect(renewed == [row.id])
        #expect(asleepWhenRenewed == false)
        #expect(row.initialCommand == "renewed")
        #expect(!row.asleep)
        #expect(row.asleepSince == nil)
        #expect(row.offScreenSince == nil)
        let woke = kinds(.sessionWoke)
        #expect(woke.count == 1)
        #expect(woke.first?.session == row.id.uuidString)
        #expect(woke.first?.payload.reason == "shown")
    }

    @Test func aWakeOffScreenStartsTheClockAtNow() throws {
        let store = makeStore(onRowWake: { { _ in } })
        let row = try remoteRow(in: store)
        #expect(store.sleepRemoteRow(row.id, reason: .timer))
        let now = Date(timeIntervalSince1970: 2_000)

        #expect(store.wakeRemoteRow(row.id, reason: .command, onScreen: false, now: now))

        #expect(row.offScreenSince == now)
        #expect(kinds(.sessionWoke).first?.payload.reason == "command")
    }

    @Test(arguments: [false, true]) func aWakeWithNoRenewalLeavesTheRowAsleep(_ installedGetter: Bool) throws {
        let store = makeStore(onRowWake: installedGetter ? { nil } : nil)
        let row = try remoteRow(in: store)
        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        #expect(!store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        #expect(row.asleep)
        #expect(kinds(.sessionWoke).isEmpty)
    }

    @Test func selectingAnAsleepRowWakesItShown() throws {
        var renewed: [UUID] = []
        let store = makeStore(onRowWake: { { renewed.append($0.id) } })
        defer { forgetPanes() }
        let row = try remoteRow(in: store)
        let other = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a"))
        #expect(store.selectedSessionID == other.id)
        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        store.selectSession(row.id)

        #expect(!row.asleep)
        #expect(renewed == [row.id])
        #expect(kinds(.sessionWoke).last?.payload.reason == RemoteSleepReason.shown.rawValue)
    }

    @Test func aPreservedSelectionThatLandsOnAnAsleepRowWakesIt() async throws {
        var renewed: [UUID] = []
        let store = makeStore(onRowWake: { { renewed.append($0.id) } })
        defer { forgetPanes() }
        let row = try remoteRow(in: store)
        let selected = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a"))
        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        await store.preservingSelection { _ = store.closeSession(selected.id) }

        #expect(store.selectedSessionID == row.id)
        #expect(!row.asleep)
        #expect(renewed == [row.id])
    }

    @Test func wakeShownWakesOnlyTheAsleepRowsItNames() throws {
        var renewed: [UUID] = []
        let store = makeStore(onRowWake: { { renewed.append($0.id) } })
        defer { forgetPanes() }
        let asleep = try remoteRow(in: store)
        let awake = try remoteRow(in: store)
        #expect(store.sleepRemoteRow(asleep.id, reason: .timer))

        store.wakeShown([asleep.id, awake.id, UUID()])

        #expect(!asleep.asleep)
        #expect(renewed == [asleep.id])
        #expect(asleep.offScreenSince == nil)
    }

    @Test func wakingAnAwakeRowDoesNothing() throws {
        var renewals = 0
        let store = makeStore(onRowWake: { { _ in renewals += 1 } })
        let row = try remoteRow(in: store)

        #expect(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        #expect(renewals == 0)
        #expect(kinds(.sessionWoke).isEmpty)
    }

    @Test func libraryStoresLoadedBeforeAndAfterTheHookIsSetBothReachIt() throws {
        let library = WindowLibrary(directory: directory)
        let launch = try #require(library.activeStore)
        var renewed: [UUID] = []
        library.onRowWake = { renewed.append($0.id) }
        let later = try #require(library.store(for: library.newWindow(name: "later").id))
        let first = try remoteRow(in: launch)
        let second = try remoteRow(in: later)
        #expect(launch.sleepRemoteRow(first.id, reason: .timer))
        #expect(later.sleepRemoteRow(second.id, reason: .timer))

        #expect(launch.wakeRemoteRow(first.id, reason: .shown, onScreen: true))
        #expect(later.wakeRemoteRow(second.id, reason: .shown, onScreen: true))

        #expect(renewed == [first.id, second.id])
    }

    @Test func aLibraryWithNoHookLeavesTheRowAsleep() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let row = try remoteRow(in: store)
        #expect(store.sleepRemoteRow(row.id, reason: .timer))

        #expect(!store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))

        #expect(row.asleep)
    }

    @Test func anAwakeRowsTreeNodeCarriesNoSleepKeys() throws {
        defer { forgetPanes() }
        let store = makeStore()
        let row = try remoteRow(in: store)

        let node = try #require(store.controlTree(paneForeground: { _ in nil }).workspaces
            .flatMap(\.sessions).first { $0.id == row.id.uuidString })
        let json = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)

        #expect(node.asleep == nil)
        #expect(!json.contains("asleep"))
    }

    @Test func anAsleepRowReadsBackAsleepAndTheTreeLeavesItAsleep() throws {
        defer { forgetPanes() }
        var renewals = 0
        let store = makeStore(onRowWake: { { _ in renewals += 1 } })
        let row = try remoteRow(in: store)
        #expect(store.sleepRemoteRow(row.id, reason: .command, now: Date(timeIntervalSince1970: 1_500)))

        let node = try #require(store.controlTree(paneForeground: { _ in nil }).workspaces
            .flatMap(\.sessions).first { $0.id == row.id.uuidString })

        #expect(node.asleep == true)
        #expect(node.asleepSince == 1_500)
        #expect(row.asleep)
        #expect(renewals == 0)
        #expect(kinds(.sessionWoke).isEmpty)
    }

    @Test func sleepRefusalNamesWhyARowCannotSleepAndIsNilWhenItCan() throws {
        defer { forgetPanes() }
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/repo"))
        let page = Session(initialCwd: "/srv", remoteHost: "box", content: .page)
        let catalog = try remoteRow(in: store)
        store.bindRemote(RemoteBinding(remoteSessionID: "c", daemonsByLocalPane: [:], presentationVersion: 1, catalogOwned: true),
                         forSession: catalog.id)
        let ended = try remoteRow(in: store)
        store.bindRemote(RemoteBinding(remoteSessionID: "e", daemonsByLocalPane: [:], presentationVersion: 1), forSession: ended.id)
        store.setRemoteRowState(.endedOnHost, forSession: ended.id)
        let busy = try remoteRow(in: store)
        busy.scratchActive = true
        let free = try remoteRow(in: store)

        #expect(local.sleepRefusal == "not a remote row")
        #expect(page.sleepRefusal == "a page row does not sleep")
        #expect(catalog.sleepRefusal == "a remote window's row does not sleep")
        #expect(ended.sleepRefusal == "its origin session has ended")
        #expect(busy.sleepRefusal == "it shows a local scratch, overlay or ask")
        #expect(free.sleepRefusal == nil)
        for row in [local, page, catalog, ended, busy, free] {
            #expect((row.sleepRefusal == nil) == row.sleepEligible)
        }
    }
}

private final class SleepSpySurface: TerminalSurface {
    let paneToken = ""
    let isRealized = true
    var teardownCount = 0
    var prepareCount = 0
    var sleepCount = 0
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() {}
    func prepareForTransfer() { prepareCount += 1 }
    func releaseForSleep() { sleepCount += 1 }
}
