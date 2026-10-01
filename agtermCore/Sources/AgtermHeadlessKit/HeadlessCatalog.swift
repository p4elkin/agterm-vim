import agtermCore

public enum HeadlessSupport: Equatable, Sendable {
    case served
    case refused(String)
}

public enum HeadlessCatalog {
    public static func support(for command: Command) -> HeadlessSupport {
        let reason: String
        switch command {
        case .tree, .eventsRead, .version, .windowList, .zmxTree, .zmxPresent, .zmxList,
             .notify, .sessionStatus, .sessionContext, .sessionSeen, .sessionNew, .sessionMark,
             .sessionClose, .sessionRename, .zmxKill, .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionText,
             .sessionHudOpen, .sessionHudUpdate, .sessionHudClose, .askOpen, .askResult, .askCancel, .zmxNew:
            return .served
        case .windowNew, .windowSelect, .windowGo, .windowClose, .windowRename, .windowDelete,
             .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize,
             .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceSelect, .workspaceGo,
             .workspaceMove, .workspaceFocus, .workspaceFilter, .workspaceCollapse, .workspaceExpand,
             .sidebar, .sidebarMode, .sidebarFlaggedLayout, .sidebarExpand, .sidebarCollapse,
             .sidebarParked, .sidebarWidth, .normalMode, .themeSet, .themeList,
             .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList, .configReload,
             .quick, .quickType, .quickText, .dashboard, .debugAppearance,
             .sessionSelect, .sessionGo, .sessionReveal, .sessionMove, .sessionDuplicate,
             .sessionFlag, .sessionPark, .sessionFocus, .sessionResize, .sessionBackground:
            reason = "no windows or UI"
        case .sessionType, .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch,
             .surfaceZoom, .surfaceCursor, .sessionScratch, .sessionLead:
            reason = "no terminal surface"
        case .sessionPairing, .overlayRedirectToggle, .sessionBookmarkAdd, .sessionBookmarkList,
             .sessionBookmarkGo, .sessionBookmarkRemove, .hooksReload, .hooksList, .sessionRestore,
             .restoreClear, .restoreCapture, .restoreMode, .zmxPrune, .zmxReset, .zmxAttach:
            reason = "a Mac feature"
        case .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayReload,
             .sessionOverlayNavigate, .sessionOverlayResult, .sessionOverlayCopy, .sessionOverlayText,
             .sessionOverlayJobRun, .pickOpen, .pickResult, .pickCancel:
            reason = "later phase"
        }
        return .refused("\(command.rawValue) is not available on a headless origin: \(reason)")
    }
}
