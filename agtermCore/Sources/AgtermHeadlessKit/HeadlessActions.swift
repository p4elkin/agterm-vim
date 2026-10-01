import agtermCore
import Foundation

/// The headless origin's `ControlActions`. Every action answers for the command that reaches it, with
/// `HeadlessCatalog`'s refusal text, so no command falls through to a generic "unsupported" default.
@MainActor
public final class HeadlessActions: ControlActions {
    private let headless: Headless
    private let identity: AppIdentity
    private let hudClock: () -> Date
    private struct HudAutoHide {
        let revision: UUID
        let deadline: Date
        let task: Task<Void, Never>
    }
    private var hudAutoHide: [UUID: HudAutoHide] = [:]

    public init(headless: Headless, installDirectory: URL, hudClock: @escaping () -> Date = Date.init) {
        self.headless = headless
        self.hudClock = hudClock
        let commit = (try? String(contentsOf: installDirectory.appendingPathComponent("BUILD"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        identity = AppIdentity(version: Headless.programVersion, recordedCommit: commit)
    }

    /// The socket server's answer; nil once a `zmx.present` stream has taken the connection over.
    public func serve(_ request: ControlRequest, connection: Int32) async -> ControlResponse? {
        let response = await respond(to: request)
        guard request.cmd == .zmxPresent, response.ok, let id = response.result?.id else { return response }
        return adoptPresentation(session: id, connection: connection)
    }

    /// The dispatcher's answer, or the catalog's for a command the dispatcher leaves to the host.
    public func respond(to request: ControlRequest) async -> ControlResponse {
        guard let response = await ControlDispatcher(actions: self).dispatch(request) else { return refuse(request.cmd) }
        // the dispatcher routes `session.bookmark.go` through `searchSession`; only the request knows which it was
        if request.cmd == .sessionBookmarkGo, response == refuse(.sessionSearch) { return refuse(.sessionBookmarkGo) }
        return response
    }

    private func refuse(_ command: Command) -> ControlResponse {
        guard case .refused(let text) = HeadlessCatalog.support(for: command) else { return notImplemented(command) }
        return ControlResponse(ok: false, error: text)
    }

    private func notImplemented(_ command: Command) -> ControlResponse {
        ControlResponse(ok: false, error: "\(command.rawValue) is not implemented yet")
    }

    // MARK: Served

    public func controlTree(window: String?) -> ControlResponse {
        guard let store = store(window: window) else { return missingWindow(window) }
        return ControlResponse(ok: true, result: ControlResult(tree: store.controlTree(paneForeground: { _ in nil }, app: identity)))
    }

    public func readEvents(_ options: ControlEventReadOptions) -> ControlResponse { headless.library.readEvents(options) }
    public func appIdentity() -> ControlResponse { ControlResponse(ok: true, result: ControlResult(app: identity)) }

    public func windowList() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(windows: headless.library.controlWindowNodes()))
    }

    public func remoteTree(host: String?) async -> ControlResponse {
        guard host?.isEmpty ?? true else {
            return ControlResponse(ok: false, error: "the headless origin answers only its own tree")
        }
        let result = await headless.runner.runInBackground(["list"], timeout: Headless.commandTimeout)
        return daemonListResponse(result, remote: true)
    }

    public func openPresentation(session: String) -> ControlResponse { headless.presentationResponse(session) }

    /// After a successful dispatch, the adapter sends the ok reply and owns the connection on nil.
    public func adoptPresentation(session: String, connection: Int32) -> ControlResponse? {
        headless.openPresentation(session, fd: connection)
    }

    public func listZmxDaemons() -> ControlResponse {
        daemonListResponse(headless.runner.run(["list"], timeout: Headless.commandTimeout), remote: false)
    }

    public func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse {
        withSession(target, window: window) { store, session in
            session.unseenCount += 1
            store.recordNotificationEvent(forSession: session.id, title: title ?? "", body: body, origin: .control)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) async -> ControlResponse {
        withSession(target, window: window) { store, session in
            let pane = update.paneID.flatMap { session.paneRole(forToken: $0) } ?? update.pane
            let indicator = AgentIndicator(status: update.status, blink: update.blink ?? false,
                                           autoReset: update.autoReset ?? false, color: update.color,
                                           shape: update.shape, statusPane: pane)
            if case .refused(let owner) = store.applyControlStatus(indicator, forSession: session.id) {
                return ControlResponse(ok: false, error: "blocked status owned by pane \(owner.rawValue)")
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func setSessionContext(_ target: String?, window: String?, context: String?) -> ControlResponse {
        withSession(target, window: window) { store, session in
            store.setContext(context, forSession: session.id)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func markSessionSeen(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { store, session in
            store.clearUnseen(session.id)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// A viewer's `seen` stands for opening the row there, so it also runs the auto-reset a selection
    /// runs on the Mac; `session.seen` clears the count alone.
    static func markSessionSeen(_ session: Session, in store: AppStore) {
        store.clearUnseen(session.id)
        if session.agentIndicator.autoReset { store.setAgentIndicator(AgentIndicator(), forSession: session.id) }
    }

    public func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        headless.newSession(name: options.name, command: options.command, cwd: options.cwd)
    }

    public func createAttachableSession(_ options: ControlZmxNewOptions) -> ControlResponse {
        headless.newSession(name: options.name, command: options.command, cwd: options.cwd)
    }

    public func markSessionTurn(_ target: String?, window: String?, paneID: String?) -> ControlResponse {
        withSession(target, window: window) { store, session in
            ControlResponse(ok: true, result: ControlResult(count: store.markTurn(session.id)))
        }
    }

    private func store(window: String?) -> AppStore? {
        guard let window else { return headless.primaryStore }
        guard case .resolved(let id) = headless.library.resolveWindow(window) else { return nil }
        return headless.library.store(for: id)
    }

    private func missingWindow(_ window: String?) -> ControlResponse {
        ControlResponse(ok: false, error: "no such open window: \(window ?? "(none)")")
    }

    private func withSession(_ target: String?, window: String?, _ action: (AppStore, Session) -> ControlResponse) -> ControlResponse {
        let selected = store(window: window)
        if window != nil, selected == nil { return missingWindow(window) }
        guard let (store, session) = headless.resolve(target), window == nil || store === selected else {
            return headless.notFound(target)
        }
        return action(store, session)
    }

    private func daemonListResponse(_ result: ZmxResult, remote: Bool) -> ControlResponse {
        let output: String
        switch result {
        case .ok(let text): output = text
        case .timedOut: return ControlResponse(ok: false, error: "zmx list timed out")
        case .failed(let status, let error): return ControlResponse(ok: false, error: "zmx list failed (\(status)): \(error)")
        case .launchFailed(let error): return ControlResponse(ok: false, error: "could not start zmx list: \(error)")
        }
        do {
            let inventory = headless.inventory(observed: try ZmxListParser.parse(output))
            return remote ? headless.attachableSessions(inventory: inventory) : ControlResponse(ok: true, result: ControlResult(zmx: inventory))
        } catch {
            return ControlResponse(ok: false, error: "could not read the zmx session list: \(error)")
        }
    }

    // MARK: Sessions

    public func duplicateSession(_ target: String?, window: String?) -> ControlResponse { refuse(.sessionDuplicate) }
    public func selectSession(_ target: String?, window: String?) -> ControlResponse { refuse(.sessionSelect) }
    public func goSession(window: String?, direction: SessionNavigation) -> ControlResponse { refuse(.sessionGo) }
    public func closeSession(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { store, session in
            headless.closeSession(session, in: store)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// Every target resolves before any closes, so a typo closes nothing.
    public func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        var resolved: [(AppStore, Session)] = []
        for target in targets {
            let response = withSession(target, window: window) { store, session in
                if !resolved.contains(where: { $0.1 === session }) { resolved.append((store, session)) }
                return ControlResponse(ok: true)
            }
            guard response.ok else { return response }
        }
        for (store, session) in resolved { headless.closeSession(session, in: store) }
        return ControlResponse(ok: true, result: ControlResult(affected: resolved.count))
    }

    public func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse {
        withSession(target, window: window) { store, session in
            store.renameSession(session.id, to: name)
            headless.persist(store)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }
    public func revealSession(_ target: String?, window: String?) -> ControlResponse { refuse(.sessionReveal) }

    public func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        refuse(.sessionMove)
    }

    public func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        refuse(.sessionMove)
    }

    public func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse { refuse(.sessionFlag) }

    public func setSessionParked(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        refuse(.sessionPark)
    }

    public func addSessionBookmark(_ target: String?, window: String?, turn: Int?, prompt: String) -> ControlResponse {
        refuse(.sessionBookmarkAdd)
    }

    public func listSessionBookmarks(_ target: String?, window: String?, all: Bool) -> ControlResponse {
        refuse(.sessionBookmarkList)
    }

    public func removeSessionBookmark(_ target: String?, window: String?, turn: Int) -> ControlResponse {
        refuse(.sessionBookmarkRemove)
    }

    public func setSessionRestore(_ target: String?, window: String?, update: ControlSessionRestoreUpdate) -> ControlResponse {
        refuse(.sessionRestore)
    }

    public func setSessionBackground(_ target: String?, window: String?,
                                     options: ControlSessionBackgroundOptions) -> ControlResponse {
        refuse(.sessionBackground)
    }

    public func setOverlayPairing(_ target: String?, window: String?,
                                  update: ControlOverlayPairingUpdate) -> ControlResponse {
        refuse(.sessionPairing)
    }

    // MARK: Workspaces

    public func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse { refuse(.workspaceNew) }
    public func selectWorkspace(_ target: String?, window: String?) -> ControlResponse { refuse(.workspaceSelect) }
    public func goWorkspace(window: String?, direction: WorkspaceNavigation) -> ControlResponse { refuse(.workspaceGo) }

    public func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        refuse(.workspaceRename)
    }

    public func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse { refuse(.workspaceDelete) }

    public func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse {
        refuse(.workspaceMove)
    }

    public func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse {
        refuse(.workspaceFocus)
    }

    public func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse { refuse(.workspaceFilter) }

    public func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        refuse(expanded ? .workspaceExpand : .workspaceCollapse)
    }

    // MARK: Panes and surfaces

    public func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        splitSession(target, window: window, mode: mode, axis: nil, command: nil)
    }

    public func splitSession(_ target: String?, window: String?, mode: String?, axis: SplitAxis?) -> ControlResponse {
        splitSession(target, window: window, mode: mode, axis: axis, command: nil)
    }

    public func splitSession(_ target: String?, window: String?, mode: String?, axis: SplitAxis?,
                             command: ControlSplitCommand?) -> ControlResponse {
        withSession(target, window: window) { store, session in
            headless.splitSession(session, in: store, mode: mode, axis: axis, command: command)
        }
    }

    public func closeSessionSplit(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { store, session in
            guard session.hasSplit else { return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString)) }
            return headless.killPane(.right, of: session, in: store)
        }
    }

    public func swapSessionPanes(_ target: String?, window: String?) async -> ControlResponse {
        withSession(target, window: window) { store, session in
            if let refusal = store.swapPanes(session.id) {
                let error: String
                switch refusal {
                case .noSession: error = "session closed during swap"
                case .noSplit: error = "session has no split pane"
                case .slotNotRealized: error = "session not realized"
                case .roleNotMutable: error = "session panes do not support swapping"
                }
                return ControlResponse(ok: false, error: error)
            }
            headless.persist(store)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func takeSessionLead(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse { refuse(.sessionLead) }

    public func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse {
        refuse(.sessionScratch)
    }

    public func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse { refuse(.sessionFocus) }

    public func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse {
        refuse(.sessionResize)
    }

    public func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        refuse(.surfaceZoom)
    }

    public func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse { refuse(.surfaceCursor) }

    public func font(_ target: String?, window: String?, pane: StatusPane?, action: String) -> ControlResponse {
        switch action {
        case "increase_font_size:1": return refuse(.fontInc)
        case "decrease_font_size:1": return refuse(.fontDec)
        default: return refuse(.fontReset)
        }
    }

    public func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse {
        refuse(.sessionType)
    }

    public func copySessionSelection(_ target: String?, window: String?) -> ControlResponse { refuse(.sessionCopy) }
    public func pasteSession(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse { refuse(.sessionPaste) }
    public func selectAllSession(_ target: String?, window: String?) -> ControlResponse { refuse(.sessionSelectAll) }

    public func searchSession(_ target: String?, window: String?, text: String?, to: String?) async -> ControlResponse {
        refuse(.sessionSearch)
    }

    public func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        withSession(target, window: window) { _, session in
            let pane = options.paneID.flatMap { session.paneRole(forToken: $0) } ?? options.pane
                ?? (session.focusedPane == .right ? .right : .left)
            let identity: UUID
            switch pane {
            case .left: identity = session.paneIdentity
            case .right:
                guard session.hasSplit, let split = session.splitPaneIdentity else {
                    return ControlResponse(ok: false, error: "session has no split pane")
                }
                identity = split
            case .scratch: return ControlResponse(ok: false, error: "session has no scratch terminal")
            }
            let daemon = ZmxSupport.daemonName(for: identity)
            let result = headless.runner.run(["history", daemon], timeout: Headless.commandTimeout)
            switch result {
            case .ok(let text):
                guard let lines = options.lines else { return ControlResponse(ok: true, result: ControlResult(text: text)) }
                // Like the Mac surface reader, count content lines rather than trailing blank grid rows.
                var rows = text.components(separatedBy: "\n")
                while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
                return ControlResponse(ok: true, result: ControlResult(text: rows.suffix(lines).joined(separator: "\n")))
            case .timedOut: return ControlResponse(ok: false, error: "zmx history timed out")
            case .failed(let status, let error): return ControlResponse(ok: false, error: "zmx history failed (\(status)): \(error)")
            case .launchFailed(let error): return ControlResponse(ok: false, error: "could not start zmx history: \(error)")
            }
        }
    }

    // MARK: Overlays, HUD, pickers, asks

    public func openSessionOverlay(_ target: String?, window: String?,
                                   options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        refuse(.sessionOverlayOpen)
    }

    public func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        refuse(.sessionOverlayClose)
    }

    public func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        refuse(.sessionOverlayResize)
    }

    public func reloadSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, current: Bool) -> ControlResponse {
        refuse(.sessionOverlayReload)
    }

    public func navigateSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?,
                                       navigation: HtmlNavigation) -> ControlResponse {
        refuse(.sessionOverlayNavigate)
    }

    public func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        refuse(.sessionOverlayResult)
    }
    public func submitSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, value: String) -> ControlResponse {
        refuse(.sessionOverlaySubmit)
    }

    public func copySessionOverlaySelection(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        refuse(.sessionOverlayCopy)
    }

    public func readSessionOverlayText(_ target: String?, window: String?,
                                       options: ControlSessionOverlayTextOptions) -> ControlResponse {
        refuse(.sessionOverlayText)
    }

    public func claimOverlayJob(_ job: String) -> ControlResponse { refuse(.sessionOverlayJobRun) }
    public func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        openHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    public func openHud(_ target: String?, window: String?, spec: HudSpec, placement: ControlHudPlacement) -> ControlResponse {
        withPaneSession(target, window: window, placement: (placement.pane, placement.paneID),
                        invalidPaneError: "hud pane must be left or right") { store, session, pane in
            guard store.openHud(session.id, command: "", spec: spec, file: "", size: hudSize(spec), paneIdentity: pane) else {
                return ControlResponse(ok: false, error: "overlay already open")
            }
            armHudAutoHide(session, in: store, spec: spec)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        updateHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    public func updateHud(_ target: String?, window: String?, spec: HudSpec, placement: ControlHudPlacement) -> ControlResponse {
        withPaneSession(target, window: window, placement: (placement.pane, placement.paneID),
                        invalidPaneError: "hud pane must be left or right") { store, session, pane in
            guard store.updateHud(session.id, spec: spec, size: hudSize(spec), paneIdentity: pane) else {
                return ControlResponse(ok: false, error: OverlayHudError.noHud)
            }
            armHudAutoHide(session, in: store, spec: spec)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func closeHud(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { store, session in
            guard store.closeHud(session.id) else { return ControlResponse(ok: false, error: OverlayHudError.noHud) }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    private func hudSize(_ spec: HudSpec) -> HudPanelSize {
        HudPanelSize(widthPercent: HudLayout.clampSizePercent(spec.sizePercent ?? HudLayout.maxSizePercent),
                     heightPercent: HudLayout.minSizePercent)
    }

    private func withPaneSession(_ target: String?, window: String?, placement: (pane: OverlayPane?, paneID: String?),
                                 invalidPaneError: String, _ action: (AppStore, Session, UUID?) -> ControlResponse) -> ControlResponse {
        withSession(target, window: window) { store, session in
            var pane = placement.pane
            if let token = placement.paneID, !token.isEmpty {
                if let role = session.paneRole(forToken: token) {
                    guard role != .scratch else { return ControlResponse(ok: false, error: invalidPaneError) }
                    pane = role == .left ? .left : .right
                } else if pane == nil {
                    return ControlResponse(ok: false, error: "unknown pane id: \(token)")
                }
            }
            let identity: UUID?
            switch pane {
            case nil: identity = nil
            case .left: identity = session.paneIdentity
            case .right:
                guard session.hasSplit, let split = session.splitPaneIdentity else {
                    return ControlResponse(ok: false, error: "session has no split")
                }
                identity = split
            }
            return action(store, session, identity)
        }
    }

    private func armHudAutoHide(_ session: Session, in store: AppStore, spec: HudSpec) {
        let id = session.id
        hudAutoHide.removeValue(forKey: id)?.task.cancel()
        session.onHudDiscarded = { [weak self] in
            MainActor.assumeIsolated { self?.hudAutoHide.removeValue(forKey: id)?.task.cancel() }
        }
        let seconds = min(spec.effectiveHideAfter, HudSpec.maxHideAfter)
        if seconds.isFinite, seconds > 0 {
            let revision = UUID()
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.expireHud(id, revision: revision)
            }
            hudAutoHide[id] = HudAutoHide(revision: revision, deadline: hudClock().addingTimeInterval(seconds), task: task)
        }
        store.publishHud(forSession: id, expiresAt: hudAutoHide[id]?.deadline, now: hudClock())
    }

    func expireHuds() {
        let now = hudClock()
        for (id, timer) in hudAutoHide where timer.deadline <= now {
            expireHud(id, revision: timer.revision)
        }
    }

    private func expireHud(_ id: UUID, revision: UUID) {
        guard hudAutoHide[id]?.revision == revision else { return }
        hudAutoHide.removeValue(forKey: id)?.task.cancel()
        headless.library.store(forSession: id)?.closeHud(id)
    }
    public func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse { refuse(.pickOpen) }
    public func pickResult(_ target: String, window: String?) -> ControlResponse { refuse(.pickResult) }
    public func cancelPick(_ target: String, window: String?) -> ControlResponse { refuse(.pickCancel) }

    public func openAsk(_ ask: PendingAsk, target: String?, window: String?,
                        placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        guard ask.style != .gui else {
            return ControlResponse(ok: false, error: "gui asks are not available on a headless origin; use --style terminal")
        }
        return withPaneSession(target, window: window, placement: (placement.pane, placement.paneID),
                               invalidPaneError: "ask pane must be left or right") { store, session, pane in
            guard let windowID = headless.library.windowID(for: store) else { return headless.notFound(target) }
            let opened: Bool
            if let presented = store.presentAsk(ask, in: session, paneIdentity: pane, window: windowID) {
                opened = presented
            } else {
                opened = session.openAsk(ask, paneIdentity: pane)
                if opened { AskRegistry.shared.register(id: ask.id, owner: .session(session.id, window: windowID)) }
            }
            guard opened else { return ControlResponse(ok: false, error: "ask already pending") }
            return ControlResponse(ok: true, result: ControlResult(id: ask.id,
                pane: pane.flatMap { session.paneRole(forIdentity: $0)?.rawValue }))
        }
    }

    public func askResult(_ target: String, window: String?) -> ControlResponse {
        withAskResult(target, window: window) { ControlResponse(ok: true, result: ControlResult(ask: $0)) }
    }

    public func cancelAsk(_ target: String, window: String?) -> ControlResponse {
        withAskResult(target, window: window) { result in
            guard result.result == .pending else { return ControlResponse(ok: true) }
            guard case .session(let id, let windowID) = AskRegistry.shared.owner(for: target),
                  let session = headless.library.store(for: windowID)?.session(withID: id) else {
                return ControlResponse(ok: false, error: "unknown ask: \(target)")
            }
            session.cancelAsk(id: target)
            return ControlResponse(ok: true)
        }
    }

    private func withAskResult(_ id: String, window: String?, _ action: (ControlAskResult) -> ControlResponse) -> ControlResponse {
        guard let retained = AskRegistry.shared.result(for: id) else { return ControlResponse(ok: false, error: "unknown ask: \(id)") }
        if let window {
            guard case .resolved(let windowID) = headless.library.resolveWindow(window) else { return missingWindow(window) }
            guard windowID == retained.windowID else { return ControlResponse(ok: false, error: "unknown ask: \(id)") }
        }
        return action(retained.result)
    }

    // MARK: App, sidebar, quick terminal

    public func setDashboard(targets: [String], window: String?, close: Bool,
                             fontMode: DashboardFontMode, mru: Bool) -> ControlResponse {
        refuse(.dashboard)
    }

    public func reloadKeymap() -> ControlResponse { refuse(.keymapReload) }
    public func listKeymap() -> ControlResponse { refuse(.keymapList) }
    public func reloadHooks() -> ControlResponse { refuse(.hooksReload) }
    public func listHooks() -> ControlResponse { refuse(.hooksList) }
    public func reloadGhosttyConfig() -> ControlResponse { refuse(.configReload) }
    public func setTheme(args: ControlArgs?) -> ControlResponse { refuse(.themeSet) }
    public func listThemes() -> ControlResponse { refuse(.themeList) }
    public func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse { refuse(.sidebar) }
    public func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse { refuse(.sidebarMode) }

    public func setSidebarParked(window: String?, mode: ControlParkedVisibilityMode,
                                 scope: ControlParkedScope) -> ControlResponse {
        refuse(.sidebarParked)
    }

    public func setFlaggedViewLayout(_ mode: ControlFlaggedLayoutMode) -> ControlResponse { refuse(.sidebarFlaggedLayout) }
    public func expandSidebar(window: String?) -> ControlResponse { refuse(.sidebarExpand) }
    public func collapseSidebar(window: String?) -> ControlResponse { refuse(.sidebarCollapse) }
    public func setSidebarWidth(_ points: Double, window: String?) -> ControlResponse { refuse(.sidebarWidth) }
    public func setNormalMode(_ mode: ControlToggleMode) -> ControlResponse { refuse(.normalMode) }
    public func setOverlayRedirectToggle(_ mode: ControlToggleMode) -> ControlResponse { refuse(.overlayRedirectToggle) }
    public func setQuickTerminal(mode: String?) -> ControlResponse { refuse(.quick) }
    public func typeQuick(text: String) async -> ControlResponse { refuse(.quickType) }
    public func readQuickText(all: Bool, lines: Int?) async -> ControlResponse { refuse(.quickText) }

    // MARK: Windows

    public func windowNew(name: String?, minimized: Bool) async -> ControlResponse { refuse(.windowNew) }
    public func windowSelect(_ target: String?) async -> ControlResponse { refuse(.windowSelect) }
    public func windowGo(direction: WorkspaceNavigation) -> ControlResponse { refuse(.windowGo) }
    public func windowClose(_ target: String?) async -> ControlResponse { refuse(.windowClose) }
    public func windowRename(_ target: String?, name: String) -> ControlResponse { refuse(.windowRename) }
    public func windowDelete(_ target: String?) -> ControlResponse { refuse(.windowDelete) }
    public func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse { refuse(.windowResize) }
    public func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse { refuse(.windowMove) }
    public func windowZoom(_ target: String?) -> ControlResponse { refuse(.windowZoom) }
    public func windowFullscreen(_ target: String?) -> ControlResponse { refuse(.windowFullscreen) }
    public func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse { refuse(.windowMinimize) }

    // MARK: Restore and zmx

    public func clearRestoreCommands() -> ControlResponse { refuse(.restoreClear) }
    public func captureRestoreCommands() -> ControlResponse { refuse(.restoreCapture) }
    public func readRestoreMode() -> ControlResponse { refuse(.restoreMode) }
    public func setRestoreMode(_ mode: RestoreMode) -> ControlResponse { refuse(.restoreMode) }
    public func pruneZmxDaemons() -> ControlResponse { refuse(.zmxPrune) }
    public func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole) -> ControlResponse {
        withSession(target, window: window) { store, session in headless.killPane(pane, of: session, in: store) }
    }
    public func resetLiveSessions() -> ControlResponse { refuse(.zmxReset) }
    public func attachRemoteSession(host: String, session: String) async -> ControlResponse { refuse(.zmxAttach) }

    public func attachRemoteSession(host: String, session: String, window: String?) async -> ControlResponse {
        refuse(.zmxAttach)
    }

    public func attachRemoteSession(host: String, session: String, window: String?,
                                    transport: RemoteTransport) async -> ControlResponse {
        refuse(.zmxAttach)
    }
}
