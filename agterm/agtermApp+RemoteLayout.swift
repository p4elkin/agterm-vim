import agtermCore
import Foundation

extension agtermApp {
    @MainActor
    static func applyRemoteLayout(_ layout: PresentationLayout, store: AppStore, sessionID: UUID, library: WindowLibrary) {
        // a split the origin keeps hidden grows once it is shown, so the Mac never holds an ssh for an unseen pane
        if layout.shown, let added = store.remoteLayoutAddedPane(layout, forSession: sessionID) {
            growRemoteSplit(attachedTo: added, axis: layout.axis, store: store, sessionID: sessionID)
        }
        for local in store.applyRemoteLayout(layout, forSession: sessionID) {
            closeRemovedRemotePane(local, store: store, sessionID: sessionID, library: library)
        }
    }

    @MainActor
    private static func growRemoteSplit(attachedTo remotePane: UUID, axis: String?, store: AppStore, sessionID: UUID) {
        guard let session = store.session(withID: sessionID),
              let origin = session.remotePresentation?.binding.origin else { return }
        let daemon = ZmxSupport.daemonName(for: remotePane)
        // no claim: the pane appeared because the origin split, not because someone asked for it here
        let lead = ZmxLeadAttachment(claim: false)
        guard let command = try? RemoteSession.attachPaneCommand(host: origin.host, endpoint: origin.endpoint, daemon: daemon,
                                                                 session: origin.sessionName, pane: .right, lead: lead,
                                                                 transport: origin.transport)
        else { return }
        session.splitInitialCommand = command
        session.splitCommandWait = true
        store.setSplitVisibility(sessionID, shown: true, axis: axis.flatMap(SplitAxis.init(rawValue:)) ?? .leftRight)
        guard let local = session.splitPaneIdentity else { return }
        ZmxLeadBook.shared.begin(lead, pane: local)
        store.addRemotePane(local: local, daemon: daemon, forSession: sessionID)
    }

    @MainActor
    static func handleRemotePaneHeld(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID, library: WindowLibrary) {
        guard let session = store.session(withID: sessionID) else { return }
        let local: UUID
        if session.surface === view {
            local = session.paneIdentity
        } else if session.splitSurface === view, let split = session.splitPaneIdentity {
            local = split
        } else {
            return
        }
        store.remotePaneHeld(local, forSession: sessionID)
        closeRemovedRemotePane(local, store: store, sessionID: sessionID, library: library)
        remotePaneExitHeld?(local, sessionID)
    }

    /// The remote row supervisor's entry, installed once by the app.
    @MainActor static var remotePaneExitHeld: ((_ local: UUID, _ session: UUID) -> Void)?

    @MainActor
    private static func closeRemovedRemotePane(_ local: UUID, store: AppStore, sessionID: UUID, library: WindowLibrary) {
        guard store.canCloseRemovedRemotePane(local, forSession: sessionID),
              let session = store.session(withID: sessionID) else { return }
        let split = session.splitPaneIdentity == local
        let surface = split ? session.splitSurface : session.surface
        if split, surface == nil {
            store.closeSplit(sessionID)
            return
        }
        guard let view = surface as? GhosttySurfaceView else { return }
        let survivor = split ? session.surface : session.splitSurface
        // the last replica keeps its terminal until ssh exits; no empty row needs a replacement factory
        guard survivor?.isRealized == true || store.remotePaneIsHeld(local, forSession: sessionID),
              view.claimProcessExit() else { return }
        handlePaneExit(view, store: store, sessionID: sessionID, library: library)
    }
}
