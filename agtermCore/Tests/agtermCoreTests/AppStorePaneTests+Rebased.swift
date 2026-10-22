import Foundation
import Testing
@testable import agtermCore

@MainActor
extension AppStorePaneTests {
    @Test(arguments: OverlayPane.allCases)
    func hidingAPaneRebasedOverlayReturnsInputWithoutReleasingIt(pane: OverlayPane) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        session.surface = SpySurface()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        session.splitFocused = pane == .right
        let overlay = RebasedOverlay(project: "/tmp/repo")
        var releases: [UUID] = []
        RebasedOverlayReleases.shared.onRelease = { releases.append($0) }
        defer { RebasedOverlayReleases.shared.onRelease = nil }
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: pane) == nil)
        #expect(session.paneOverlayVisible(pane))
        #expect(session.paneRebasedOverlayActive(pane))
        #expect(session.rebasedHidesTerminal(pane == .left ? .left : .right))
        #expect(!session.rebasedHidesTerminal(pane == .left ? .right : .left))
        #expect(!session.rebasedHidesTerminal(.scratch))
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        #expect(session.paneOverlay(pane)?.hidden == true && session.rebasedHidden)
        #expect(!session.paneOverlayVisible(pane))
        #expect(!session.paneRebasedOverlayActive(pane))
        #expect(!session.rebasedHidesTerminal(pane == .left ? .left : .right))
        #expect(session.focusedOverlayPane == nil)
        #expect(!session.programOverlayOwnsKeyboard)
        #expect(session.topmostSurface === session.activeSurface)
        #expect(session.focusTarget(wantSplit: pane == .right) === session.activeSurface)
        #expect(session.openPaneOverlays == [pane])
        #expect(store.openPaneOverlay(session.id, pane: pane, command: "other") == .alreadyOpen)
        #expect(store.openHtmlOverlay(session.id, pane: pane, overlay: HtmlOverlay(source: .file(path: "/tmp/a.html", grantRoot: nil)),
                                     sizePercent: nil) == .alreadyOpen)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, false) == nil)
        #expect(session.paneOverlayVisible(pane))
        #expect(session.focusedOverlayPane == pane)
        #expect(session.topmostSurface == nil)
        #expect(releases.isEmpty)
        #expect(store.closeRebasedOverlay(session.id, id: overlay.id))
        #expect(releases == [overlay.id])
    }

    @Test(arguments: ["session", "left", "right"])
    func everyHideRouteFlipsTheIDEsSlotBitAndTellsTheApp(slot: String) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.toggleSplit(session.id)
        let pane = OverlayPane(rawValue: slot)
        let overlay = RebasedOverlay(project: "/tmp/repo")
        var heard: [Bool] = []
        RebasedOverlayReleases.shared.onHiddenChange = { sessionID, id, hidden in
            #expect(sessionID == session.id && id == overlay.id)
            heard.append(hidden)
        }
        defer { RebasedOverlayReleases.shared.onHiddenChange = nil }
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: pane) == nil)
        #expect(store.toggleOverlaysHidden(session.id, pane: nil) == nil)
        #expect(session.rebasedHidden)
        if pane != nil {
            #expect(session.hiddenOverlayNames == [slot])
            #expect(store.setOverlaysHidden(session.id, pane: pane, hidden: true) == nil)
        }
        #expect(store.setRebasedHidden(session.id, id: overlay.id, false) == nil)
        #expect(!session.rebasedHidden)
        #expect(heard == [true, false])
    }

    @Test func hidingAnotherSlotLeavesTheIDEAlone() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.toggleSplit(session.id)
        let overlay = RebasedOverlay(project: "/tmp/repo")
        var heard: [Bool] = []
        RebasedOverlayReleases.shared.onHiddenChange = { _, _, hidden in heard.append(hidden) }
        defer { RebasedOverlayReleases.shared.onHiddenChange = nil }
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .left) == nil)
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        #expect(store.setOverlaysHidden(session.id, pane: .right, hidden: true) == nil)
        #expect(heard.isEmpty && !session.rebasedHidden)
    }

    @Test func aHiddenSessionWideRebasedOverlayIsNotVisibleAndCoversNoTerminal() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let overlay = RebasedOverlay(project: "/tmp/repo")
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil) == nil)
        #expect(session.rebasedOverlayVisible)
        #expect(!session.rebasedHidden)
        #expect(([nil] + StatusPane.allCases.map(Optional.some)).allSatisfy { session.rebasedHidesTerminal($0) })
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        #expect(!session.rebasedOverlayVisible)
        #expect(!session.rebasedOverlayActive && !session.overlayActive && session.rebasedHidden)
        #expect(([nil] + StatusPane.allCases.map(Optional.some)).allSatisfy { !session.rebasedHidesTerminal($0) })
    }

    @Test(arguments: OverlayPane.allCases)
    func rebasedPaneOpenKeepsTheOtherPaneInteractive(pane: OverlayPane) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        session.surface = SpySurface()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        session.splitFocused = pane == .right
        let overlay = RebasedOverlay(project: "/tmp/repo")
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: pane) == nil)
        #expect(session.paneOverlay(pane)?.rebased == overlay)
        #expect(session.rebasedOverlay == nil)
        #expect(!session.coverOverlayActive)
        #expect(!session.rebasedOverlayActive)
        #expect(session.focusedOverlayPane == pane)
        #expect(session.programOverlayOwnsKeyboard)
        #expect(session.topmostSurface == nil)
        #expect(session.focusTarget(wantSplit: pane == .right) == nil)
        #expect(!session.paneOverlayIsProgram(pane))
        #expect(session.openPaneOverlays == [pane])
        #expect(session.topmostHtmlOverlay == nil)
        #expect(!session.htmlHidesTerminal(pane == .left ? .left : .right))
        #expect(store.htmlOverlayCommandFailure(session.id, pane: pane) == .notHtml)
        session.splitFocused.toggle()
        #expect(!session.programOverlayOwnsKeyboard)
        #expect(session.topmostSurface === session.activeSurface)
        #expect(session.focusTarget(wantSplit: pane == .left) === session.activeSurface)
    }

    @Test(arguments: ["session", "left", "right"])
    func rebasedOpenRefusesASecondHolderAnywhere(slot: String) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.toggleSplit(session.id)
        let pane = OverlayPane(rawValue: slot)
        let overlay = RebasedOverlay(project: "/tmp/repo")
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: pane) == nil)
        for target: OverlayPane? in [nil, .left, .right] {
            #expect(store.openRebasedOverlay(session.id, overlay: RebasedOverlay(project: "/other"),
                                            sizePercent: nil, pane: target) == .alreadyOpen)
            #expect(session.rebasedPlacement?.overlay == overlay)
            #expect(session.rebasedPlacement?.pane == pane)
        }
    }

    @Test func rebasedPaneOpenRefusesOccupiedOrUnrenderedPanes() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let overlay = RebasedOverlay(project: "/tmp/repo")
        let failure = store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .right)
        #expect(failure == .paneNotVisible)
        #expect(failure?.message(pane: .right) == PaneOverlayError.paneNotVisible)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "reader") == nil)
        let occupied = store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .left)
        #expect(occupied == .alreadyOpen)
        #expect(occupied?.message(pane: .left) == PaneOverlayError.alreadyOpen)
        #expect(session.leftOverlay?.command == "reader")
    }

    @Test func rebasedPaneSurvivesUnmountAndPromotionWithoutRelease() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.toggleSplit(session.id)
        let overlay = RebasedOverlay(project: "/tmp/repo")
        var releases: [UUID] = []
        RebasedOverlayReleases.shared.onRelease = { releases.append($0) }
        defer { RebasedOverlayReleases.shared.onRelease = nil }
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .right) == nil)
        session.splitFocused = false
        store.setSplitVisibility(session.id, shown: false)
        #expect(session.rebasedPlacement?.pane == .right)
        session.promotePaneOverlay()
        #expect(session.rebasedPlacement?.pane == .left)
        #expect(session.rebasedPlacement?.overlay.id == overlay.id)
        #expect(session.rightOverlay == nil)
        #expect(releases.isEmpty)
    }

    @Test(arguments: ["close", "teardown", "split", "session", "pending", "window"])
    func rebasedPaneReleaseRunsOnce(path: String) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.toggleSplit(session.id)
        let overlay = RebasedOverlay(project: "/tmp/repo")
        var releases: [UUID] = []
        RebasedOverlayReleases.shared.onRelease = { releases.append($0) }
        defer { RebasedOverlayReleases.shared.onRelease = nil }
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil, pane: .right) == nil)
        switch path {
        case "close": #expect(store.closePaneOverlay(session.id, pane: .right))
        case "split": store.closeSplit(session.id)
        case "session": store.closeSession(session.id)
        case "pending":
            #expect(store.softCloseSession(session.id, grace: 60))
            #expect(releases.isEmpty)
            store.finalizeAllPendingCloses()
        case "window": session.teardownPaneOverlays()
        default: session.teardownPaneOverlay(.right)
        }
        session.teardownPaneOverlay(.right)
        #expect(!store.closePaneOverlay(session.id, pane: .right))
        #expect(session.rebasedPlacement == nil)
        #expect(releases == [overlay.id])
    }

    @Test(arguments: ["session", "left", "right"])
    func rebasedUpdateAndCloseFollowTheOverlayID(slot: String) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.toggleSplit(session.id)
        let overlay = RebasedOverlay(project: "/tmp/repo")
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil,
                                        pane: OverlayPane(rawValue: slot)) == nil)
        #expect(!session.updateRebasedOverlay(UUID()) { $0.project = "/wrong" })
        #expect(session.updateRebasedOverlay(overlay.id) {
            $0.project = "/mirror"
            $0.source = "host:/repo"
            $0.state = .shown
        })
        #expect(session.rebasedPlacement?.overlay.project == "/mirror")
        #expect(session.rebasedPlacement?.overlay.source == "host:/repo")
        #expect(session.rebasedPlacement?.overlay.state == .shown)
        #expect(!store.closeRebasedOverlay(session.id, id: UUID()))
        #expect(session.rebasedPlacement?.overlay.id == overlay.id)
        #expect(store.closeRebasedOverlay(session.id, id: overlay.id))
        #expect(session.rebasedPlacement == nil)
        #expect(!store.closeRebasedOverlay(session.id, id: overlay.id))
        #expect(!store.closeRebasedOverlay(UUID(), id: overlay.id))
    }

    @Test func aHiddenSessionWideIDELeavesTheSlotToAProgramAndAPage() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let overlay = RebasedOverlay(project: "/tmp/repo")
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: 60) == nil)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        #expect(!session.overlayActive && !session.overlayHidden && session.rebasedOverlay == nil)
        #expect(session.overlaySizePercent == nil)
        #expect(session.rebasedPlacement?.overlay == overlay && session.rebasedPlacement?.pane == nil)
        #expect(store.openOverlay(session.id, command: "fzf"))
        #expect(store.setRebasedHidden(session.id, id: overlay.id, false) == .unpark(.alreadyOpen))
        #expect(session.overlayCommand == "fzf" && session.rebasedHidden)
        #expect(store.closeOverlay(session.id))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: HtmlOverlay(source: .file(path: "/tmp/a.html", grantRoot: nil)),
                                     sizePercent: nil) == nil)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, false) == .unpark(.alreadyOpen))
        #expect(session.htmlOverlayActive && session.rebasedHidden)
    }

    @Test func showingAParkedIDERefusesWhileARemoteReservationHoldsTheSlot() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let overlay = RebasedOverlay(project: "/tmp/repo")
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil) == nil)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        session.remoteOverlays.reserve(RemoteOverlaySlot(job: "job", pane: nil, owner: 1, sizePercent: nil))
        #expect(!store.sessionSlotFree(session))
        let failure = store.setRebasedHidden(session.id, id: overlay.id, false)
        #expect(failure == .unpark(.alreadyOpen))
        #expect(failure?.message == "overlay already open")
        #expect(session.rebasedHidden && !session.overlayActive)
    }

    @Test(arguments: [false, true])
    func showingAParkedIDESeatsItWithItsSize(overHud: Bool) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let overlay = RebasedOverlay(project: "/tmp/repo")
        var heard: [Bool] = []
        RebasedOverlayReleases.shared.onHiddenChange = { sessionID, id, hidden in
            #expect(sessionID == session.id && id == overlay.id)
            heard.append(hidden)
        }
        defer { RebasedOverlayReleases.shared.onHiddenChange = nil }
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: 60) == nil)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        #expect(heard == [true])
        if overHud {
            #expect(store.openHud(session.id, command: "hud", spec: HudSpec(message: "x"), file: "/tmp/h",
                                  size: HudPanelSize(widthPercent: 30, heightPercent: 10)))
        }
        #expect(store.sessionSlotFree(session))
        let generation = session.overlaySlotGeneration
        #expect(store.setRebasedHidden(session.id, id: overlay.id, false) == nil)
        #expect(session.rebasedOverlay == overlay && session.parkedRebased == nil)
        #expect(session.rebasedOverlayVisible && !session.rebasedHidden && !session.hudActive)
        #expect(session.overlaySizePercent == 60)
        #expect(session.overlaySlotGeneration > generation)
        #expect(heard == [true, false])
    }

    @Test(arguments: ["close", "session"])
    func aParkedIDEIsReleasedOnce(path: String) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let overlay = RebasedOverlay(project: "/tmp/repo")
        var releases: [UUID] = []
        RebasedOverlayReleases.shared.onRelease = { releases.append($0) }
        defer { RebasedOverlayReleases.shared.onRelease = nil }
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil) == nil)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        #expect(store.openOverlay(session.id, command: "fzf"))
        #expect(releases.isEmpty)
        if path == "close" {
            #expect(store.closeRebasedOverlay(session.id, id: overlay.id))
            #expect(!store.closeRebasedOverlay(session.id, id: overlay.id))
            #expect(session.overlayCommand == "fzf")
        } else {
            store.closeSession(session.id)
        }
        #expect(session.rebasedPlacement == nil)
        #expect(releases == [overlay.id])
    }

    @Test func aParkedIDEFollowsUpdatesAndReadsBackHiddenWithoutAPane() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let overlay = RebasedOverlay(project: "/tmp/repo")
        #expect(store.openRebasedOverlay(session.id, overlay: overlay, sizePercent: nil) == nil)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true) == nil)
        #expect(session.updateRebasedOverlay(overlay.id) { $0.state = .shown })
        #expect(session.rebasedPlacement?.overlay.state == .shown)
        #expect(store.openRebasedOverlay(session.id, overlay: RebasedOverlay(project: "/other"), sizePercent: nil) == .alreadyOpen)
        let node = try #require(store.controlTree().workspaces.first?.sessions.first)
        #expect(node.overlay == false)
        #expect(node.rebasedOverlay?.hidden == true && node.rebasedOverlay?.pane == nil)
        #expect(store.setRebasedHidden(session.id, id: UUID(), false) == .noOverlay)
        #expect(store.setRebasedHidden(session.id, id: UUID(), false)?.message == "no Rebased overlay in this session")
    }
}
