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
        #expect(session.paneOverlayCovers(pane))
        #expect(session.paneRebasedOverlayActive(pane))
        #expect(store.setRebasedHidden(session.id, id: overlay.id, true))
        #expect(!session.paneOverlayCovers(pane))
        #expect(!session.paneRebasedOverlayActive(pane))
        #expect(session.focusedOverlayPane == nil)
        #expect(!session.programOverlayOwnsKeyboard)
        #expect(session.topmostSurface === session.activeSurface)
        #expect(session.focusTarget(wantSplit: pane == .right) === session.activeSurface)
        #expect(session.openPaneOverlays == [pane])
        #expect(store.openPaneOverlay(session.id, pane: pane, command: "other") == .alreadyOpen)
        #expect(store.openHtmlOverlay(session.id, pane: pane, overlay: HtmlOverlay(source: .file(path: "/tmp/a.html", grantRoot: nil)),
                                     sizePercent: nil) == .alreadyOpen)
        #expect(store.setRebasedHidden(session.id, id: overlay.id, false))
        #expect(session.paneOverlayCovers(pane))
        #expect(session.focusedOverlayPane == pane)
        #expect(session.topmostSurface == nil)
        #expect(releases.isEmpty)
        #expect(store.closeRebasedOverlay(session.id, id: overlay.id))
        #expect(releases == [overlay.id])
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
}
