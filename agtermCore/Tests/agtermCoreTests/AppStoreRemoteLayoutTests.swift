import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRemoteLayoutTests {
    let originA = UUID()
    let originB = UUID()

    private func attached() throws -> (AppStore, Session) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "origin"))
        store.toggleSplit(session.id)
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: originA),
            try #require(session.splitPaneIdentity): ZmxSupport.daemonName(for: originB),
        ], presentationVersion: 1), forSession: session.id)
        return (store, session)
    }

    private func singlePane() throws -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "origin"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin",
            daemonsByLocalPane: [session.paneIdentity: ZmxSupport.daemonName(for: originA)], presentationVersion: 1),
            forSession: session.id)
        return (store, session)
    }

    @Test func aReleasedHoldIsForgotten() throws {
        let (store, session) = try singlePane()
        store.remotePaneHeld(session.paneIdentity, forSession: session.id)
        #expect(store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))
        store.releaseRemotePaneHold(session.paneIdentity, forSession: session.id)
        #expect(!store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))
    }

    @Test func growingTheBindingKeepsModeLayoutAndHeldPanes() throws {
        let (store, session) = try singlePane()
        store.setRemoteMode(.presenter, forSession: session.id)
        store.setRemoteConnection(.connected, forSession: session.id)
        let layout = PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true)
        store.applyRemoteLayout(layout, forSession: session.id)
        store.remotePaneHeld(session.paneIdentity, forSession: session.id)
        var expected = try #require(session.remotePresentation)
        store.toggleSplit(session.id)
        let local = try #require(session.splitPaneIdentity)
        let daemon = ZmxSupport.daemonName(for: originB)
        expected.binding = expected.binding.adding(localPane: local, daemon: daemon)
        store.addRemotePane(local: local, daemon: daemon, forSession: session.id)
        #expect(session.remotePresentation == expected)
        #expect(session.remotePresentation?.binding.localPane(forRemote: originB) == local)
    }

    @Test(arguments: [false, true])
    func aNewOriginPaneIsFoundRegardlessOfPrimaryOrder(reordered: Bool) throws {
        let (store, session) = try singlePane()
        let layout = PresentationLayout(panes: reordered ? [originB, originA] : [originA, originB],
            primary: reordered ? originB : originA, axis: "horizontal", shown: false)
        #expect(store.remoteLayoutAddedPane(layout, forSession: session.id) == originB)
        #expect(!session.hasSplit)
        #expect(session.remotePresentation?.layout == nil)
    }

    @Test func invalidUnrelatedAndAlreadyMappedLayoutsNeverGrowAReplica() throws {
        let (store, session) = try singlePane()
        let layouts = [
            PresentationLayout(panes: [originA], primary: originA, shown: false),
            PresentationLayout(panes: [originA, originA], primary: originA, axis: "vertical", shown: true),
            PresentationLayout(panes: [originA, originB], primary: originA, axis: "bad", shown: true),
            PresentationLayout(panes: [originA, originB], primary: UUID(), axis: "vertical", shown: true),
            PresentationLayout(panes: [originB, UUID()], primary: originB, axis: "vertical", shown: true),
        ]
        for layout in layouts { #expect(store.remoteLayoutAddedPane(layout, forSession: session.id) == nil) }
        let valid = PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true)
        #expect(store.remoteLayoutAddedPane(valid, forSession: UUID()) == nil)
        store.addRemotePane(local: UUID(), daemon: ZmxSupport.daemonName(for: originB), forSession: session.id)
        #expect(store.remoteLayoutAddedPane(valid, forSession: session.id) == nil)
    }

    @Test func anExistingLocalSplitPreventsOriginPaneGrowth() throws {
        let (store, session) = try singlePane()
        store.toggleSplit(session.id)
        let layout = PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true)
        #expect(store.remoteLayoutAddedPane(layout, forSession: session.id) == nil)
    }

    @Test func layoutReordersOnlyExistingReplicasAndKeepsFocusOnItsPane() throws {
        let (store, session) = try attached()
        let primary = session.paneIdentity
        let split = try #require(session.splitPaneIdentity)
        session.splitFocused = false
        session.splitRatio = 0.35
        let layout = PresentationLayout(panes: [originB, originA], primary: originB, axis: "horizontal", shown: false)

        #expect(store.applyRemoteLayout(layout, forSession: session.id).isEmpty)

        #expect(session.paneIdentity == split)
        #expect(session.splitPaneIdentity == primary)
        #expect(session.splitFocused)
        #expect(session.splitRatio == 0.35)
        #expect(session.splitAxis == .topBottom)
        #expect(!session.isSplit)
        #expect(session.hasSplit)
        let removal = PresentationLayout(panes: [originB], primary: originB, shown: false)
        #expect(store.applyRemoteLayout(removal, forSession: session.id) == [primary])
    }

    @Test func aClosedReplicaIsNeverRecreated() throws {
        let (store, session) = try attached()
        store.closeSplit(session.id)
        let layout = PresentationLayout(panes: [originA, originB], primary: originA, axis: "horizontal", shown: true)

        #expect(store.applyRemoteLayout(layout, forSession: session.id).isEmpty)

        #expect(!session.hasSplit)
        #expect(session.splitPaneIdentity == nil)
        #expect(session.splitSurface == nil)
    }

    @Test(arguments: [false, true])
    func aLocalSplitIsNeitherReorderedNorHidden(pending: Bool) throws {
        let (store, session) = try attached()
        store.closeSplit(session.id)
        store.toggleSplit(session.id)
        if !pending { session.splitSurface = SpySurface() }
        let local = session.splitPaneIdentity
        let primary = session.paneIdentity
        let layout = PresentationLayout(panes: [originB, originA], primary: originB, axis: "horizontal", shown: false)

        #expect(store.applyRemoteLayout(layout, forSession: session.id).isEmpty)

        #expect(session.splitPaneIdentity == local)
        #expect(session.paneIdentity == primary)
        #expect(session.isSplit)
        #expect(session.splitAxis == .leftRight)
        let removed = PresentationLayout(panes: [originB], primary: originB, shown: false)
        _ = store.applyRemoteLayout(removed, forSession: session.id)
        #expect(store.canCloseRemovedRemotePane(primary, forSession: session.id) == !pending)
        #expect(!store.canCloseRemovedRemotePane(try #require(local), forSession: session.id))
    }

    @Test func anUnrealizedReplicaIsNotShownByALayout() throws {
        let (store, session) = try attached()
        (session.splitSurface as? SpySurface)?.isRealized = false
        store.setSplitVisibility(session.id, shown: false)

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, originB], primary: originA,
                                                       axis: "vertical", shown: true), forSession: session.id)

        #expect(!session.isSplit)
    }

    @Test func originPublishesModelMembershipOncePerChangeAndSeedsLateSubscribers() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        session.surface = SpySurface(backedByZmx: true)
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let sink = PresentationHubTests.Sink()
        try hub.subscribe(session: session.id, hello: PresentationHubTests.hello, sink: sink) {
            store.presentationSnapshot(forSession: session.id)
        }
        store.toggleSplit(session.id)
        let split = try #require(session.splitPaneIdentity)
        #expect(session.splitSurface == nil)
        #expect(sink.frames.last?.body == .layout(PresentationLayout(panes: [session.paneIdentity, split],
                                                                    primary: session.paneIdentity, axis: "vertical", shown: true)))
        let count = sink.frames.count
        store.setSplitVisibility(session.id, shown: true)
        #expect(sink.frames.count == count)
        store.setSplitVisibility(session.id, shown: false)
        store.setSplitVisibility(session.id, shown: true, axis: .topBottom)
        session.splitSurface = SpySurface(backedByZmx: true)
        #expect(store.swapPanes(session.id) == nil)
        store.closePrimaryPane(session.id)
        #expect(sink.frames.count == count + 4)
        let late = PresentationHubTests.Sink()
        try hub.subscribe(session: session.id, hello: PresentationHubTests.hello, sink: late) {
            store.presentationSnapshot(forSession: session.id)
        }
        #expect(late.frames.last?.body == .snapshot(store.presentationSnapshot(forSession: session.id)))
        #expect(store.presentationSnapshot(forSession: session.id).layout?.panes == [session.paneIdentity])
    }

    @Test func anAttachedRowNeverPublishesLayout() throws {
        let (store, session) = try attached()
        let hub = PresentationHub(staleTimeout: 30)
        let sink = PresentationHubTests.Sink()
        store.presentationHub = hub
        try hub.subscribe(session: session.id, hello: PresentationHubTests.hello, sink: sink) {
            store.presentationSnapshot(forSession: session.id)
        }
        store.setSplitVisibility(session.id, shown: false)
        store.closeSplit(session.id)
        #expect(sink.frames.count == 2)
        #expect(store.presentationSnapshot(forSession: session.id).layout == nil)
    }
}
