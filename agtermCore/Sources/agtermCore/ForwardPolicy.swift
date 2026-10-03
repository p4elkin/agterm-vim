/// Where a request made on a headless origin is answered. The origin routes by it and a Mac re-checks it before
/// running a forwarded request, so it is the one allowlist. No `default`: a new command fails the build until classified.
public enum ForwardPolicy {
    public enum Kind: Equatable, Sendable {
        case served
        case forwarded
        /// Decided per request by `route(_:holdsJob:)`: the overlay family.
        case routed
        case refused(String)
    }

    public enum Route: Equatable, Sendable {
        case served
        /// A program overlay the origin books and the presenter runs over ssh.
        case job
        case forwarded
        case refused(String)
    }

    public static func kind(of command: Command) -> Kind {
        switch command {
        case .tree, .eventsRead, .version, .windowList, .zmxTree, .zmxPresent, .zmxList,
             .notify, .sessionStatus, .sessionContext, .sessionSeen, .sessionNew, .sessionMark,
             .sessionClose, .sessionRename, .zmxKill, .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionText, .sessionType,
             .sessionHudOpen, .sessionHudUpdate, .sessionHudClose, .askOpen, .askResult, .askCancel, .zmxNew,
             .sessionOverlayJobRun:
            return .served
        case .sessionOverlayReload, .sessionOverlayNavigate, .sessionOverlaySubmit, .sessionOverlayCopy, .sessionOverlayText,
             .pickOpen, .pickResult, .pickCancel,
             .sessionFlag, .sessionSelect, .sessionReveal, .sessionFocus, .sessionBackground,
             .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch,
             .sessionBookmarkAdd, .sessionBookmarkList, .sessionBookmarkGo, .sessionBookmarkRemove:
            return .forwarded
        case .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult:
            return .routed
        case .windowNew, .windowSelect, .windowGo, .windowClose, .windowRename, .windowDelete,
             .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize,
             .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceSelect, .workspaceGo,
             .workspaceMove, .workspaceFocus, .workspaceFilter, .workspaceCollapse, .workspaceExpand,
             .sidebar, .sidebarMode, .sidebarFlaggedLayout, .sidebarExpand, .sidebarCollapse,
             .sidebarParked, .sidebarWidth, .normalMode, .themeSet, .themeList,
             .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList, .keymapRun, .configReload,
             .quick, .quickType, .quickText, .dashboard, .debugAppearance,
             .sessionGo, .sessionMove, .sessionDuplicate, .sessionPark, .sessionResize:
            return .refused("no windows or UI")
        // a forwarded scratch would open a login shell on the Mac
        case .surfaceZoom, .surfaceCursor, .sessionScratch, .sessionLead:
            return .refused("no terminal surface")
        case .sessionPairing, .overlayRedirectToggle, .hooksReload, .hooksList, .sessionRestore,
             .restoreClear, .restoreCapture, .restoreMode, .zmxPrune, .zmxReset, .zmxAttach, .zmxScreen, .browserClear:
            return .refused("a Mac feature")
        }
    }

    /// `holdsJob` says whether the origin holds a program overlay job on the addressed pane; a Mac passes false.
    public static func route(_ request: ControlRequest, holdsJob: Bool) -> Route {
        switch kind(of: request.cmd) {
        case .served where request.cmd == .sessionType && request.args?.select == true:
            return .refused("it has no selection")
        case .served: return .served
        case .forwarded: return .forwarded
        case .refused(let reason): return .refused(reason)
        case .routed:
            switch request.cmd {
            // the page is a file the Mac would read from its own disk
            case .sessionOverlayOpen where request.args?.html != nil:
                return .refused("an --html page is a file on the origin; use --url")
            case .sessionOverlayOpen: return request.args?.url == nil ? .job : .forwarded
            // the Mac would answer a program poll with its ssh helper's status
            case .sessionOverlayResult: return request.args?.page == nil ? .served : .forwarded
            case .sessionOverlayClose, .sessionOverlayResize: return holdsJob ? .served : .forwarded
            default: return .refused("not routed")
            }
        }
    }
}
