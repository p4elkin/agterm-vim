import agtermCore

/// One request per `Command`, each with the fewest arguments that pass the dispatcher's own validation and
/// reach an action.
enum HeadlessRequests {
    static let target = "00000000-0000-0000-0000-000000000001"

    static let all: [ControlRequest] = [
        request(.tree),
        request(.eventsRead),
        request(.version),
        request(.windowList),
        request(.zmxNew) { $0.command = "true" },
        request(.zmxTree),
        request(.zmxPresent, target: target),
        request(.zmxList),
        request(.notify, target: target) { $0.body = "b" },
        request(.sessionStatus, target: target) { $0.status = "idle" },
        request(.sessionContext, target: target) { $0.mode = "clear" },
        request(.sessionSeen, target: target),
        request(.sessionNew) { $0.command = "true" },
        request(.sessionMark, target: target),

        request(.windowNew),
        request(.windowSelect, target: target),
        request(.windowGo) { $0.to = "next" },
        request(.windowClose, target: target),
        request(.windowRename, target: target) { $0.name = "w" },
        request(.windowDelete, target: target),
        request(.windowResize, target: target) {
            $0.width = 100
            $0.height = 100
        },
        request(.windowMove, target: target) {
            $0.x = 0
            $0.y = 0
        },
        request(.windowZoom, target: target),
        request(.windowFullscreen, target: target),
        request(.windowMinimize, target: target),
        request(.workspaceNew),
        request(.workspaceRename, target: target) { $0.name = "w" },
        request(.workspaceDelete, target: target),
        request(.workspaceSelect, target: target),
        request(.workspaceGo) { $0.to = "next" },
        request(.workspaceMove, target: target) { $0.to = "up" },
        request(.workspaceFocus, target: target),
        request(.workspaceFilter),
        request(.workspaceCollapse, target: target),
        request(.workspaceExpand, target: target),
        request(.sidebar),
        request(.sidebarMode),
        request(.sidebarFlaggedLayout),
        request(.sidebarExpand),
        request(.sidebarCollapse),
        request(.sidebarParked),
        request(.sidebarWidth) { $0.sidebarWidth = 200 },
        request(.normalMode),
        request(.themeSet),
        request(.themeList),
        request(.fontInc),
        request(.fontDec),
        request(.fontReset),
        request(.keymapReload),
        request(.keymapList),
        request(.keymapRun) { $0.name = "c" },
        request(.configReload),
        request(.quick),
        request(.quickType) { $0.text = "x" },
        request(.quickText),
        request(.dashboard) { $0.mru = true },
        request(.debugAppearance),
        request(.sessionSelect, target: target),
        request(.sessionGo) { $0.to = "next" },
        request(.sessionReveal, target: target),
        request(.sessionMove, target: target) { $0.to = "up" },
        request(.sessionDuplicate, target: target),
        request(.sessionFlag, target: target),
        request(.sessionPark, target: target),
        request(.sessionFocus, target: target),
        request(.sessionResize, target: target) { $0.ratio = 0.5 },
        request(.sessionBackground, target: target),

        request(.sessionType, target: target) { $0.text = "x" },
        request(.sessionCopy, target: target),
        request(.sessionPaste, target: target),
        request(.sessionSelectAll, target: target),
        request(.sessionSearch, target: target) { $0.text = "x" },
        request(.surfaceZoom, target: target),
        request(.surfaceCursor, target: target),
        request(.sessionScratch, target: target),
        request(.sessionLead, target: target),

        request(.sessionPairing, target: target) {
            $0.mode = "mirrors"
            $0.host = ""
        },
        request(.overlayRedirectToggle),
        request(.sessionBookmarkAdd, target: target),
        request(.sessionBookmarkList, target: target),
        request(.sessionBookmarkGo, target: target) { $0.turn = 1 },
        request(.sessionBookmarkRemove, target: target) { $0.turn = 1 },
        request(.hooksReload),
        request(.hooksList),
        request(.sessionRestore, target: target) { $0.mode = "none" },
        request(.restoreClear),
        request(.restoreCapture),
        request(.restoreMode),
        request(.zmxPrune),
        request(.zmxScreen) { $0.name = "d" },
        request(.zmxReset) { $0.force = true },
        request(.zmxAttach, target: target) { $0.host = "h" },
        request(.browserClear),
        request(.browserLinks),
        request(.sessionRestart, target: target) { $0.pane = "left" },

        request(.sessionClose, target: target),
        request(.sessionRename, target: target) { $0.name = "s" },
        request(.sessionSplit, target: target),
        request(.sessionSplitClose, target: target),
        request(.sessionSwap, target: target),
        request(.sessionText, target: target),
        request(.zmxKill, target: target) {
            $0.pane = "left"
            $0.force = true
        },
        request(.sessionHudOpen, target: target) { $0.message = "m" },
        request(.sessionHudUpdate, target: target) { $0.message = "m" },
        request(.sessionHudClose, target: target),
        request(.askOpen, target: target) {
            $0.title = "t"
            $0.buttons = [ControlAskButton(id: "ok", label: "OK")]
        },
        request(.askResult, target: target),
        request(.askCancel, target: target),
        request(.sessionOverlayOpen, target: target) { $0.command = "true" },
        request(.sessionOverlayClose, target: target),
        request(.sessionOverlayResize, target: target) { $0.full = true },
        request(.sessionOverlayReload, target: target),
        request(.sessionOverlayNavigate, target: target) { $0.to = "back" },
        request(.sessionOverlayResult, target: target),
        request(.sessionOverlaySubmit, target: target) { $0.value = "" },
        request(.sessionOverlayCopy, target: target),
        request(.sessionOverlayText, target: target),
        request(.sessionOverlayJobRun, target: target),
        request(.pickOpen, target: target) { $0.items = [ControlPickItem(id: "a", label: "A")] },
        request(.pickResult, target: target),
        request(.pickCancel, target: target),
    ]

    static func request(_ cmd: Command, target: String? = nil,
                        _ edit: (inout ControlArgs) -> Void = { _ in }) -> ControlRequest {
        var args = ControlArgs()
        edit(&args)
        return ControlRequest(cmd: cmd, target: target, args: args)
    }
}
