import AppKit
import agtermCore
import Foundation
import AgtermResponsibility
import Darwin
import os

/// The `zmx` command group: the daemon inventory and, later, the actions over it. Every command needs a
/// running instance by design — only one can join the live stores, the pending-close records, the checked
/// closed-window snapshots and the observed daemons into a single answer.
extension ControlServer {
    func liveAttributions(in sessions: [Session], leaders: [String: pid_t]?) -> [UUID: SessionHost.Placement] {
        let identities = Set(sessions.filter { $0.remoteHost == nil }.flatMap { session -> [UUID] in
            var ids = session.surface?.backedByZmx == true ? [session.paneIdentity] : []
            if session.hasSplit, session.splitSurface?.backedByZmx == true, let split = session.splitPaneIdentity { ids.append(split) }
            return ids
        })
        guard !identities.isEmpty, let leaders else { return [:] }
        let place = liveAttributionProbe.placer(endpoint: zmxClient?.endpoint)
        let unread = SessionHost.Placement(attribution: .unknown, staleHost: false)
        return Dictionary(uniqueKeysWithValues: identities.map { identity in
            let name = ZmxSupport.daemonName(for: identity)
            return (identity, leaders[name].map { place(name, $0) } ?? unread)
        })
    }

    /// The reset's read-back for the tree top level and the `zmx list` header: nil when nothing is pending
    /// and no launch consumed a marker, so an untouched instance shows no field at all.
    func liveResetReadback() -> ControlLiveResetReadback? {
        let pending = liveReset?.pending.map(\.targets.count)
        let last = liveResetOutcome()
        guard pending != nil || last != nil else { return nil }
        return ControlLiveResetReadback(pending: pending, last: last)
    }

    /// `zmx.reset`: the dialog's confirm path without the dialog. The quit is not requested here; the
    /// connection thread requests it once this reply is written.
    func resetLiveSessions() -> ControlResponse {
        guard let liveReset else {
            return ControlResponse(ok: false, error: ControlActionsUnsupported.message("zmx.reset"))
        }
        switch liveReset.request(confirmed: true) {
        case .refused(let refusal):
            return ControlResponse(ok: false, error: refusal.message)
        case .cancelled:
            return ControlResponse(ok: false, error: "zmx.reset was cancelled")
        case .confirmed(let selection):
            let outdated = selection.outdatedSessionCount
            let stale = selection.staleHostSessionCount
            let status = ControlLiveResetStatus(sessions: selection.sessionCount, panes: selection.targets.count, pending: true,
                                                outdated: outdated > 0 ? outdated : nil, staleHost: stale > 0 ? stale : nil)
            let text = LiveReset.dialogText(sessionCount: selection.sessionCount, outdatedSessions: outdated,
                                            staleHostSessions: stale).body
            return ControlResponse(ok: true, result: ControlResult(text: text, liveReset: status))
        }
    }

    /// liveResetSelection covers open and saved panes; nil when the listing failed, which refuses the action.
    func liveResetSelection() -> LiveReset.Selection? {
        guard let zmxClient, let records = zmxClient.sessionRecords() else { return nil }
        return LiveReset.select(claims: library.paneClaims(), records: records, outdatedBefore: zmxOutdatedBefore,
                                place: liveAttributionProbe.placer(endpoint: zmxClient.endpoint))
    }

    /// Observed daemons joined against the panes that claim them, with the restore status as a header.
    ///
    /// A failed listing is an error rather than an empty inventory: an empty namespace is a real answer and
    /// must not be indistinguishable from not having looked.
    func listZmxDaemons() -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let result = ZmxInventory.join(observed: observed, claims: walk.claims,
                                       inventoryComplete: walk.complete)
        let inventory = ControlZmxInventory(restore: restoreStatus(), result: result,
                                            socketDirectory: client.socketDirectory, endpoint: client.endpoint,
                                            liveReset: liveResetReadback(), outdatedBefore: zmxOutdatedBefore)
        return ControlResponse(ok: true, result: ControlResult(zmx: inventory))
    }

    /// readZmxScreen answers `zmx.screen` at the daemon's last leader's grid; it attaches nothing.
    func readZmxScreen(name: String, fullBuffer: Bool, lines: Int?) -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let screen = client.screen(name: name, all: fullBuffer) else {
            return ControlResponse(ok: false, error: "could not read the zmx screen of \(name)")
        }
        return ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
    }
}

extension ControlServer {
    /// Attachable sessions: this app's own when `host` is nil, another machine's when it is not.
    ///
    /// The remote form runs the BARE form over ssh, so the far side does the whole join in one walk of its
    /// own windows and answers with a single document. Nothing is composed across two remote calls, so
    /// there is no framing and no window where the far side's topology can move between reads.
    func remoteTree(host: String?) async -> ControlResponse {
        await remoteTree(host: host, deadline: Self.remoteTreeDeadline)
    }

    func remoteTree(host: String?, deadline: TimeInterval) async -> ControlResponse {
        guard let host else { return localAttachableSessions() }
        let argv: [String]
        do {
            argv = try RemoteSession.treeCommand(host: host)
        } catch {
            // the host is NOT echoed: reaching here means validation rejected it, and it is rejected for
            // carrying control characters, which agtermctl would print to a terminal after JSON decoding
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: deadline)
        guard result.status == 0 else {
            // stdout first: the remote's agtermctl prints a not-ok response there and exits nonzero, so
            // its own sentence never reaches stderr. ssh's own failures do. An ok-looking payload from a
            // nonzero process is never accepted, which is why the status is read before the output.
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = RemoteTreeMerger.remoteError(stdout: result.stdout) ?? (stderr.isEmpty ? nil : stderr)
            return ControlResponse(ok: false, error: detail ?? "the remote command failed on \(host)")
        }
        do {
            let remote = try RemoteTreeMerger.decode(stdout: result.stdout)
            // the far side cannot know which name reached it, so the destination we were given is stamped
            // here rather than self-reported there
            return ControlResponse(ok: true, result: ControlResult(remote: remote.stamped(host: host)))
        } catch let error as RemoteTreeMerger.MergeError {
            return ControlResponse(ok: false, error: error.message)
        } catch {
            return ControlResponse(ok: false, error: "the remote answer could not be read")
        }
    }

    /// This app's own attachable sessions, across every OPEN window. An empty list is a successful answer
    /// and does not distinguish "not running live" from "live with nothing eligible"; `zmx list` is the
    /// restore-mode diagnostic.
    private func localAttachableSessions() -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let inventory = ControlZmxInventory(restore: restoreStatus(),
                                            result: ZmxInventory.join(observed: observed,
                                                                      claims: walk.claims,
                                                                      inventoryComplete: walk.complete),
                                            socketDirectory: client.socketDirectory,
                                            endpoint: client.endpoint, liveReset: liveResetReadback(),
                                            outdatedBefore: zmxOutdatedBefore)
        // a live store IS the open-window test, the same one `openCounts` uses: a closed window has no
        // store, and its panes are not attachable from here anyway
        let windows = library.windows.compactMap { entry in
            library.store(for: entry.id).map {
                RemoteWindowProjection(id: entry.id.uuidString, name: entry.name, tree: buildTree(in: $0))
            }
        }
        do {
            let tree = try RemoteTreeMerger.candidates(windows: windows, inventory: inventory)
            return ControlResponse(ok: true, result: ControlResult(remote: tree))
        } catch let error as RemoteTreeMerger.MergeError {
            return ControlResponse(ok: false, error: error.message)
        } catch {
            return ControlResponse(ok: false, error: "the session list could not be built")
        }
    }

    /// Create a session on `host`, then attach it here exactly as `zmx attach` would. A far refusal's error
    /// comes back unchanged and creates no row. With `options.workspace` the window and workspace are pinned
    /// before the round trip, so a window brought forward meanwhile cannot redirect the row.
    func createRemoteSession(host: String, options: ControlZmxNewOptions, window: String?) async -> ControlResponse {
        var destination: RemoteDestination?
        if let workspace = options.workspace {
            switch resolveOpenWindow(window) {
            case .failure(let response): return response
            case .success(let (windowID, store)):
                let resolution = store.resolveWorkspaceTarget(workspace)
                guard case .resolved(let id) = resolution else {
                    return ControlResponse(ok: false, error: ControlResolve.errorMessage(noun: "workspace", target: workspace,
                                                                                        resolution: resolution))
                }
                destination = RemoteDestination(windowID: windowID, workspace: id, newSessionRule: nil)
            }
        }
        switch await createAndAttach(host: host, options: options, window: window, destination: destination) {
        case .attached(let row): return ControlResponse(ok: true, result: ControlResult(id: row.id.uuidString))
        case .refused(let error), .createdNotAttached(_, let error): return ControlResponse(ok: false, error: error)
        }
    }

    /// The "+" new-session controls: create on `host` into `workspace` of `store`, the control's own window,
    /// placed by the new-session placement setting read when the row is inserted. The row is selected only if
    /// the selection is still `selectionAtClick` and nothing holds it (a palette acts on the selection), so a
    /// slow host never pulls the user away.
    func createRemoteSessionForButton(host: String, workspace: UUID, in store: AppStore,
                                      selectionAtClick: UUID?) async -> RemoteCreateOutcome {
        guard let windowID = library.windowID(for: store) else { return .refused("no window to attach into") }
        guard store.workspaces.contains(where: { $0.id == workspace }) else { return .refused("the workspace is gone") }
        let rule = RemoteDestination.NewSessionRule(selectionAtRequest: selectionAtClick)
        return await createAndAttach(host: host, options: ControlZmxNewOptions(), window: nil,
                                     destination: RemoteDestination(windowID: windowID, workspace: workspace, newSessionRule: rule))
    }

    private func createAndAttach(host: String, options: ControlZmxNewOptions, window: String?,
                                 destination: RemoteDestination?) async -> RemoteCreateOutcome {
        let argv: [String]
        do {
            argv = try RemoteSession.newCommand(host: host, options: options)
        } catch {
            return .refused("invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        guard result.status == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = RemoteTreeMerger.remoteError(stdout: result.stdout) ?? (stderr.isEmpty ? nil : stderr)
            return .refused(detail ?? "the remote command failed on \(host)")
        }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            return .refused("the remote answer could not be read")
        }
        guard response.ok else { return .refused(response.error ?? "the remote command failed on \(host)") }
        guard let id = response.result?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return .refused("\(host) created a session without an id")
        }
        let found: (remote: ControlRemoteSession, tree: ControlRemoteTree)
        switch await discoverRemote(host: host, session: id) {
        case .failure(let refusal): return .createdNotAttached(remoteID: id, error: refusal.error ?? "the session could not be attached")
        case .success(let discovered): found = discovered
        }
        let attached: RemoteRowInsert
        switch remoteRow(found.remote, from: found.tree, host: host) {
        case .failure(let refusal): attached = .refused(refusal)
        case .success(let row):
            attached = attachRemoteRow(row, window: destination.map { $0.windowID.uuidString } ?? window, destination: destination)
        }
        switch attached {
        case .inserted(let row): return .attached(row)
        case .refused(let refusal): return .createdNotAttached(remoteID: id, error: refusal.error ?? "the session could not be attached")
        }
    }

    func attachRemoteSession(host: String, session: String) async -> ControlResponse {
        await attachRemoteSession(host: host, session: session, window: nil)
    }

    /// Create a local session attached to one of `host`'s.
    ///
    /// The remote is resolved again here rather than trusted from whatever the caller last saw: a picker's
    /// answer can be minutes old, and a daemon that has gone since would otherwise be CREATED by the
    /// attach, handing back a fresh shell wearing the session's name. Everything that can fail is checked
    /// before the model is touched, so a refusal leaves no half-built row behind.
    func attachRemoteSession(host: String, session: String, window: String?) async -> ControlResponse {
        await attachRemoteSession(host: host, session: session, window: window, workspace: nil)
    }

    func attachRemoteSession(host: String, session: String, window: String?,
                             workspace target: ControlAttachWorkspace?) async -> ControlResponse {
        await attachRemoteSession(host: host, session: session, window: window, target: target)
    }

    private func attachRemoteSession(host: String, session: String, window: String?,
                                     target: ControlAttachWorkspace?) async -> ControlResponse {
        let found: (remote: ControlRemoteSession, tree: ControlRemoteTree)
        switch await discoverRemote(host: host, session: session) {
        case .failure(let response): return response
        case .success(let discovered): found = discovered
        }
        if found.remote.content == "page" {
            switch resolveOpenWindow(window) {
            case .failure(let response): return response
            case .success(let (_, store)):
                return await attachRemotePageRow(found.remote, tree: found.tree, host: host, in: store, workspace: target)
            }
        }
        // a companion joins its parent's group when exactly one row here shows that parent, else it stands alone
        if found.remote.parent != nil, case .success(let (_, store)) = resolveOpenWindow(window) {
            let parents = attachedParentRows(of: found.remote, tree: found.tree, host: host, in: store)
            if parents.count == 1, let parent = parents.first, let workspace = store.workspace(forSession: parent.id)?.id {
                return attach(found.remote, from: found.tree, host: host,
                              placement: RemotePlacement(store: store, workspace: workspace, parent: parent.id))
            }
        }
        let row: RemoteRow
        switch remoteRow(found.remote, from: found.tree, host: host) {
        case .failure(let response): return response
        case .success(let built): row = built
        }
        switch attachRemoteRow(row, window: window, destination: nil, workspace: target) {
        case .refused(let response): return response
        case .inserted(let created): return ControlResponse(ok: true, result: ControlResult(id: created.id.uuidString))
        }
    }

    static let workspaceNotCreated = ControlResponse(ok: false, error: "the workspace to attach into could not be created")

    /// AttachDestination is the workspace an attach resolved: one that exists, or a name `--create-workspace` adds
    /// when the row is placed, so a refusal before that adds none.
    enum AttachDestination {
        case existing(UUID)
        case create(String)

        /// workspace is the destination's id in `store`, creating a named one now; nil when the name sanitizes to blank.
        @MainActor func workspace(in store: AppStore) -> UUID? {
            switch self {
            case .existing(let id): return id
            case .create(let name): return store.ensureWorkspace(named: name)?.id
            }
        }
    }

    /// attachWorkspace is where a row that stands alone lands in `store`: `target`, else the current workspace.
    func attachWorkspace(_ target: ControlAttachWorkspace?, in store: AppStore) -> ControlTargetResolver.Resolution<AttachDestination> {
        switch target {
        case nil:
            guard let id = store.currentWorkspaceID else {
                return .failure(ControlResponse(ok: false, error: "no window to attach into"))
            }
            return .success(.existing(id))
        case .id(let raw):
            let resolution = store.resolveWorkspaceTarget(raw)
            guard case .resolved(let id) = resolution else {
                let message = ControlResolve.errorMessage(noun: "workspace", target: raw, resolution: resolution)
                return .failure(ControlResponse(ok: false, error: message))
            }
            return .success(.existing(id))
        case .name(let name, let create):
            if let found = store.workspace(named: name) { return .success(.existing(found.id)) }
            guard create else {
                return .failure(ControlResponse(ok: false, error: "no workspace named \"\(name)\" (pass --create-workspace to add it)"))
            }
            return .success(.create(name))
        }
    }

    /// Insert a just-discovered row. Without a `destination` the window resolves after discovery and the row is
    /// appended, selected, to `target` or the current workspace; a destination's workspace is re-checked here because
    /// the round trip can outlive it.
    private func attachRemoteRow(_ row: RemoteRow, window: String?, destination: RemoteDestination?,
                                 workspace target: ControlAttachWorkspace? = nil) -> RemoteRowInsert {
        let store: AppStore
        switch resolveOpenWindow(window) {
        case .failure(let response): return .refused(response)
        case .success(let (_, resolved)): store = resolved
        }
        var placement: RemotePlacement
        if let destination {
            guard store.workspaces.contains(where: { $0.id == destination.workspace }) else {
                return .refused(ControlResponse(ok: false, error: "the workspace is gone"))
            }
            placement = RemotePlacement(store: store, workspace: destination.workspace)
            if let rule = destination.newSessionRule {
                let setting = settingsModel.settings.effectiveNewSessionPlacement
                placement.position = store.newSessionInsertionIndex(inWorkspace: destination.workspace, placement: setting)
                placement.select = store.selectedSessionID == rule.selectionAtRequest && !store.isAutoFollowSuppressed
            }
        } else {
            switch attachWorkspace(target, in: store) {
            case .failure(let response): return .refused(response)
            case .success(let resolved):
                // created only now: discovery and lookup can no longer refuse, only a payload agterm cannot address
                guard let workspace = resolved.workspace(in: store) else { return .refused(Self.workspaceNotCreated) }
                placement = RemotePlacement(store: store, workspace: workspace)
            }
        }
        // attaching is the user asking for the session HERE, so every pane claims the lead at once
        let inserted = insertRemoteRow(row, at: placement, claim: true)
        if case .inserted(let created) = inserted, placement.select {
            if destination?.newSessionRule != nil { store.noteUserActivity() }
            // a FIXED target, never `focusActiveSession`: it follows `splitFocused`, which the new split's deck
            // re-render can clear from under it through `onFocusChange`.
            actions.focusSplitPane(created, wantSplit: created.splitFocused)
        }
        return inserted
    }

    /// A headless origin's `zmx.attach --beside`: its session `session` becomes a row right after `rowID`, from the
    /// host that row already uses. Unselected, as the origin's own `zmx.new` creates it: nobody here
    /// asked to look at it. Answers with the origin's id, which is the only one the origin can use.
    func attachBeside(rowID: UUID, session: String) async -> ControlResponse {
        // an origin's session id is a UUID, and refusal text echoes it
        guard UUID(uuidString: session) != nil else { return ControlResponse(ok: false, error: "invalid remote session") }
        guard let origin = library.store(forSession: rowID)?.session(withID: rowID)?.remotePresentation?.binding.origin else {
            return ControlResponse(ok: false, error: "the row's origin is unknown")
        }
        let row: RemoteRow
        switch await discoverRemote(host: origin.host, session: session) {
        case .failure(let response): return response
        case .success(let found):
            switch remoteRow(found.remote, from: found.tree, host: origin.host) {
            case .failure(let response): return response
            case .success(let built): row = built
            }
        }
        // located again after the ssh round trip: the row may have moved or closed meanwhile
        guard let store = library.store(forSession: rowID),
              let workspace = store.workspaces.first(where: { $0.sessions.contains { $0.id == rowID } }),
              let index = workspace.sessions.firstIndex(where: { $0.id == rowID }) else {
            return ControlResponse(ok: false, error: "the row is no longer attached")
        }
        if store.workspaces.flatMap(\.sessions).contains(where: { $0.remotePresentation?.binding.remoteSessionID == session }) {
            return ControlResponse(ok: false, error: "session \(session) already has a row here")
        }
        let placement = RemotePlacement(store: store, workspace: workspace.id, position: index + 1, select: false)
        switch insertRemoteRow(row, at: placement, claim: true) {
        case .refused(let response): return response
        case .inserted: return ControlResponse(ok: true, result: ControlResult(id: session))
        }
    }

    private func discoverRemote(host: String, session: String) async
        -> ControlTargetResolver.Resolution<(remote: ControlRemoteSession, tree: ControlRemoteTree)> {
        let discovery = await remoteTree(host: host)
        guard discovery.ok, let tree = discovery.result?.remote else { return .failure(discovery) }
        // by id only: remote session names are mutable and deliberately non-unique across workspaces, and
        // `zmx tree` prints the id for exactly this hand-off
        guard let remote = tree.sessions.first(where: { $0.id == session }) else {
            return .failure(ControlResponse(ok: false, error: "no attachable session \(session) on \(host)"))
        }
        return .success((remote, tree))
    }

    private func remoteRow(_ remote: ControlRemoteSession, from tree: ControlRemoteTree,
                           host: String) -> ControlTargetResolver.Resolution<RemoteRow> {
        // by role, never by position: a payload with two lefts or no left must fail rather than quietly
        // become one pane, or the wrong one
        let byRole = Dictionary(remote.panes.map { (ZmxPaneRole(controlName: $0.pane), $0.daemon) },
                                uniquingKeysWith: { first, _ in first })
        guard byRole.count == remote.panes.count, let left = byRole[.left] else {
            return .failure(ControlResponse(ok: false, error: "\(host) reported panes agterm cannot address"))
        }
        return .success(RemoteRow(host: host, endpoint: tree.endpoint, sessionName: remote.name, remoteSessionID: remote.id,
                                  presentationVersion: tree.presentation, left: left,
                                  right: byRole[.right], splitAxis: remote.splitAxis.flatMap(SplitAxis.init(rawValue:)),
                                  name: remote.name, namePending: false, originHeadless: tree.headless == true,
                                  companions: remote.companions?.map(\.id), originParent: remote.parent))
    }

    /// RemotePlacement is where an attached row goes: a workspace, or under `parent`, a remote row of the same host.
    /// A user attach appends and selects; a restore puts the row back at `position`, unselected.
    struct RemotePlacement {
        let store: AppStore
        let workspace: UUID
        var parent: UUID?
        /// position is the row's place in the workspace; nil appends it.
        var position: Int?
        var select = true
        /// claimLead is the user asking for the session here; a row the origin's membership brought in takes no lead.
        var claimLead = true
    }

    /// attach creates the local row for `remote`, one session of `tree`, and binds its panes. Everything that can
    /// fail is checked before the model is touched.
    func attach(_ remote: ControlRemoteSession, from tree: ControlRemoteTree, host: String,
                placement: RemotePlacement) -> ControlResponse {
        let row: RemoteRow
        switch remoteRow(remote, from: tree, host: host) {
        case .failure(let response): return response
        case .success(let found): row = found
        }
        switch insertRemoteRow(row, at: placement, claim: placement.claimLead) {
        case .refused(let response): return response
        case .inserted(let created):
            // a FIXED target, never `focusActiveSession`: it follows `splitFocused`, which the new split's deck
            // re-render can clear from under it through `onFocusChange`.
            if placement.select { actions.focusSplitPane(created, wantSplit: created.splitFocused) }
            return ControlResponse(ok: true, result: ControlResult(id: created.id.uuidString, parent: placement.parent?.uuidString))
        }
    }

    /// Inserts a bound remote row and opens its presentation stream. Shared by a user attach, which has just
    /// discovered the session, and a launch restore, which trusts its saved record and inserts it `asleep`: no line,
    /// lead or pane lease until its wake. Nothing is inserted when a pane command cannot be built.
    func insertRemoteRow(_ row: RemoteRow, at placement: RemotePlacement, claim: Bool, asleep: Bool = false) -> RemoteRowInsert {
        let leads = (left: ZmxLeadAttachment(claim: claim), right: ZmxLeadAttachment(claim: claim))
        let primary: String
        let split: String?
        do {
            primary = try RemoteSession.attachPaneCommand(host: row.host, endpoint: row.endpoint, daemon: row.left,
                                                          session: row.sessionName, pane: .left, lead: leads.left)
            split = try row.right.map {
                try RemoteSession.attachPaneCommand(host: row.host, endpoint: row.endpoint, daemon: $0,
                                                    session: row.sessionName, pane: .right, lead: leads.right)
            }
        } catch {
            return .refused(ControlResponse(ok: false, error: "\(row.host) reported a session agterm cannot address"))
        }
        let store = placement.store
        // the LOCAL working directory, not the remote one: libghostty chdirs the ssh process here, and a
        // path that exists on the far side may not exist on this Mac. The attached shell reports its real
        // cwd through the terminal stream anyway.
        guard let created = store.addSession(toWorkspace: placement.workspace, cwd: NSHomeDirectory(),
                                             command: primary, name: row.name, wait: true,
                                             at: placement.position, select: placement.select,
                                             remoteHost: row.host, remoteSessionID: row.remoteSessionID,
                                             parentID: placement.parent) else {
            return .refused(ControlResponse(ok: false, error: "could not create the session"))
        }
        if let split {
            created.splitInitialCommand = split
            created.splitCommandWait = true
            store.setSplitVisibility(created.id, shown: true, axis: row.splitAxis ?? .leftRight)
            // a new split focuses its right pane; an attached session opens on its left one
            created.splitFocused = false
        }
        // the first build validated both lines; with the pane identities minted, a pooled row rebuilds them on its leases
        if asleep {
            created.initialCommand = nil
            created.splitInitialCommand = nil
            store.markRestoredAsleep(created)
        } else if let pools = library.sshHostPools {
            func pooled(_ daemon: String, pane: UUID, role: ZmxPaneRole, lead: ZmxLeadAttachment) -> String? {
                let path = pools.lease(host: row.host, user: "pane:\(pane)")
                return try? RemoteSession.attachPaneCommand(host: row.host, endpoint: row.endpoint, daemon: daemon,
                                                            session: row.sessionName, pane: role, lead: lead, controlPath: path)
            }
            if let line = pooled(row.left, pane: created.paneIdentity, role: .left, lead: leads.left) { created.initialCommand = line }
            if let right = row.right, let local = created.splitPaneIdentity,
               let line = pooled(right, pane: local, role: .right, lead: leads.right) {
                created.splitInitialCommand = line
            }
        }
        var daemons = [created.paneIdentity: row.left]
        if !asleep { ZmxLeadBook.shared.begin(leads.left, pane: created.paneIdentity) }
        if let right = row.right, let local = created.splitPaneIdentity {
            daemons[local] = right
            if !asleep { ZmxLeadBook.shared.begin(leads.right, pane: local) }
        }
        let origin = RemoteBinding.Origin(host: row.host, endpoint: row.endpoint, sessionName: row.sessionName)
        store.bindRemote(RemoteBinding(remoteSessionID: row.remoteSessionID, daemonsByLocalPane: daemons,
                                       presentationVersion: row.presentationVersion, origin: origin,
                                       originHeadless: row.originHeadless),
                         forSession: created.id, namePending: row.namePending)
        if let members = row.companions { store.baselineCompanions(members, forSession: created.id) }
        if let parent = row.originParent {
            library.markOriginCompanionsHandled([row.remoteSessionID], parent: parent, host: row.host, endpoint: row.endpoint)
        }
        // the row's created event fired inside `addSession`, before the binding existed; seeded first, so no list beats it
        startRemotePresentation(for: created)
        return .inserted(created)
    }

    /// Kill the daemons the inventory shows as unclaimed and detached.
    ///
    /// The gate is checked and revalidated, never atomic: pinned zmx has no kill-if-detached, so this
    /// re-lists immediately before mutating and drops any candidate that gained a client in between. What
    /// remains is a client attaching from outside agterm inside that gap, which the docs state plainly.
    /// Model resolution stays on this actor, so agterm's own claims cannot move underneath the operation.
    func pruneZmxDaemons() -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let inventory = ZmxInventory.join(observed: observed, claims: walk.claims,
                                          inventoryComplete: walk.complete)
        guard let candidates = ZmxPrunePolicy.namesToPrune(inventory) else {
            return ControlResponse(ok: false, error: ControlZmxError.incompleteInventory)
        }
        guard !candidates.isEmpty else {
            return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons", affected: 0))
        }

        guard let recheck = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not re-read the zmx session list before pruning")
        }
        let stillDetached = Set(recheck.filter { $0.clients == 0 }.map(\.name))
        let names = candidates.filter { stillDetached.contains($0) }
        guard !names.isEmpty else {
            return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons left to prune",
                                                                   affected: 0))
        }

        let outcomes = client.killObservedOrphan(names: names)
        let killed = outcomes.filter { $0.value == .killed }.keys.sorted()
        return ControlResponse(ok: true, result: ControlResult(text: pruneReport(outcomes),
                                                               affected: killed.count))
    }

    /// Reports per daemon rather than a bare count: a stale-socket cleanup is not a kill, and a caller that
    /// cannot tell the two apart would believe a live unresponsive daemon had gone.
    private func pruneReport(_ outcomes: [String: ZmxKillOutcome]) -> String {
        outcomes.keys.sorted().map { name in
            switch outcomes[name] {
            case .killed: return "killed \(name)"
            case .staleSocket: return "\(name): cleaned up a stale socket, the daemon may still be running"
            case .failed(let reason): return "\(name): not killed (\(reason))"
            case nil: return "\(name): no result"
            }
        }
        .joined(separator: "; ")
    }
}

extension ControlServer {
    /// Destroy one pane's daemon, then drive the same model transition the pane's own exit would have.
    ///
    /// Resolution runs against the INVENTORY rather than `ControlTargetResolver`, which searches open
    /// stores only: this command deliberately reaches closed and unindexed claims no window shows.
    func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole) -> ControlResponse {
        killZmxDaemon(target: target, window: window, pane: pane, pinned: nil)
    }

    func killZmxPane(target: String, window: String?, pane: ZmxPaneRole, paneID: String) -> ControlResponse {
        killZmxDaemon(target: target, window: window, pane: pane, pinned: paneID)
    }

    private func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole, pinned: String?) -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let inventory = ZmxInventory.join(observed: observed, claims: walk.claims,
                                          inventoryComplete: walk.complete)

        // `active` is refused on BOTH selectors rather than resolved: the contract is that nothing about
        // this destruction falls back to whatever is in front of the user, and a window selector that
        // silently means "frontmost" would reintroduce exactly that
        guard target != "active" else {
            return ControlResponse(ok: false, error: "zmx.kill needs a session id; 'active' is not accepted")
        }
        guard window != "active" else {
            return ControlResponse(ok: false, error: "zmx.kill needs a window id; 'active' is not accepted")
        }

        // an explicit --window scopes the claims BEFORE the session resolves, so a prefix ambiguous across
        // windows can be disambiguated and an exact id in another window is not killed regardless
        let windowIDs = Array(Set(inventory.rows.compactMap { $0.claim?.windowID }))
        var owned = inventory.rows.filter { $0.claim?.pane == pane }
        if let window, !window.isEmpty {
            guard case .resolved(let windowID) = ControlResolve.resolve(window, candidates: windowIDs,
                                                                        active: nil) else {
                return ControlResponse(ok: false, error: "no such window: \(window)")
            }
            owned = owned.filter { $0.claim?.windowID == windowID }
        }
        let candidates = owned.compactMap { $0.claim?.sessionID }
        guard case .resolved(let sessionID) = ControlResolve.resolve(target, candidates: candidates,
                                                                     active: nil),
              let row = owned.first(where: { $0.claim?.sessionID == sessionID }), let claim = row.claim else {
            return ControlResponse(ok: false, error: "no \(pane.rawValue) pane daemon for session \(target)")
        }
        if let refusal = ControlZmxError.killRefusal(row) {
            return ControlResponse(ok: false, error: refusal)
        }
        if let pinned, let refusal = ZmxPaneRole.pinRefusal(pinned, identity: claim.paneIdentity, pane: pane) {
            return ControlResponse(ok: false, error: refusal)
        }

        // only an exact confirmation may close a live pane. zmx exits zero after unlinking a socket it
        // could not reach, so trusting the status would let this report a kill, tear the pane down, and
        // leave the daemon running and unreachable by name.
        switch client.killConfirmed(name: row.daemon) {
        case .killed:
            break
        case .staleSocket:
            return ControlResponse(ok: false, error: "\(row.daemon) did not confirm the kill; zmx cleaned "
                + "up a stale socket and the daemon may still be running")
        case .failed(let reason):
            return ControlResponse(ok: false, error: "could not kill \(row.daemon): \(reason)")
        }
        applyKilledPaneExit(claim)
        return ControlResponse(ok: true, result: ControlResult(id: claim.sessionID.uuidString,
                                                               text: "killed \(row.daemon)",
                                                               pane: claim.pane.rawValue))
    }

    /// Runs the pane's exit transition for a daemon this command has already destroyed.
    ///
    /// Marks the surface's exit handled FIRST — after the kill, never before, so a failed kill leaves the
    /// natural path working — then drives `handlePaneExit`, which owns the model transition plus the
    /// promoted survivor's font callback, its dashboard membership and the refocus. A store-only
    /// transition would skip those three. The already-killed identity is excluded from the finalizer, or
    /// the teardown would ask zmx to kill a name that is gone and, on a session close, reach the sibling.
    private func applyKilledPaneExit(_ claim: ZmxPaneClaim) {
        guard let store = library.store(for: claim.windowID),
              let session = store.session(withID: claim.sessionID) else { return }
        let surface = claim.pane == .left ? session.surface : session.splitSurface
        if surface == nil { store.daemonKilled(claim.paneIdentity) }
        // `backedByZmx` is what makes this surface a CLIENT of the daemon just killed. On a requested-live
        // fallback the launch reap preserves claimed daemons while the pane gets a fresh plain shell, so
        // without this the kill would close a live pane that never attached to the thing it destroyed.
        guard let view = surface as? GhosttySurfaceView, view.backedByZmx,
              view.claimProcessExit() else { return }
        agtermApp.handlePaneExit(view, store: store, sessionID: claim.sessionID, library: library,
                                 alreadyFinalized: claim.paneIdentity)
    }
}

/// Error strings shared by the zmx commands, so the CLI and the server cannot word the same refusal
/// differently.
public enum ControlZmxError {
    /// Why a row may not be killed, nil when it may. `absent` has nothing to kill, and `unreadable` is
    /// refused in v1 because a forced kill there can unlink a live daemon's socket and still exit zero,
    /// leaving the process running and unreachable by name.
    static func killRefusal(_ row: ZmxInventoryRow) -> String? {
        switch row.observation {
        case .absent: return "\(row.daemon) is not running"
        case .unreadable: return "\(row.daemon) is unreadable; killing it could orphan a live daemon"
        case .running: break
        }
        switch row.state {
        case .claimed: return nil
        case .pendingClose: return "\(row.daemon) belongs to a session waiting out its undo window"
        case .unknown, .conflicted: return incompleteInventory
        case .orphan, .foreign: return "\(row.daemon) is not claimed by that pane"
        }
    }

    public static let unavailable = "zmx is unavailable in this instance"
    public static let incompleteInventory =
        "the pane inventory is incomplete or has conflicting owners, so no daemon can be safely pruned"
}

struct LiveAttributionProbe {
    /// Hosts is every host endpoint's published pid by endpoint name, and the current key's endpoint name,
    /// nil when the helper's key could not be read.
    struct Hosts: Equatable {
        var pids: [String: pid_t] = [:]
        var current: String?
    }

    var responsible: (pid_t) -> SessionHost.ResponsibleProcess = LiveAttributionProbe.lookup
    var hosts: (ControlZmxEndpoint) -> Hosts = LiveAttributionProbe.publishedHosts
    var appPID: pid_t = getpid()

    /// placer places daemon leaders against this endpoint's hosts. A published host counts only while it is its
    /// own responsible process, which disclaiming it at spawn made it.
    func placer(endpoint: ControlZmxEndpoint?) -> (String, Int32) -> SessionHost.Placement {
        var probes: [pid_t: SessionHost.ResponsibleProcess] = [:]
        func probed(_ pid: pid_t) -> SessionHost.ResponsibleProcess {
            if let cached = probes[pid] { return cached }
            let result = responsible(pid)
            probes[pid] = result
            return result
        }
        let published = endpoint.map(hosts) ?? Hosts()
        let live = published.pids.filter { probed($0.value) == .live($0.value) }
        let current: SessionHost.Roots.Current = published.current.map { live[$0].map { .running($0) } ?? .absent } ?? .unknown
        let roots = SessionHost.Roots(hosts: Set(live.values), current: current)
        return { _, leader in
            SessionHost.place(leader: leader, responsible: probed(leader), roots: roots, appPid: appPID)
        }
    }

    private static func lookup(_ leader: pid_t) -> SessionHost.ResponsibleProcess {
        guard Responsibility.system.isAvailable, let pid = Responsibility.system.responsibleProcess(of: leader) else { return .unknown }
        if kill(pid, 0) == 0 || errno == EPERM { return .live(pid) }
        return errno == ESRCH ? .dead : .unknown
    }

    static func publishedHosts(_ endpoint: ControlZmxEndpoint) -> Hosts {
        var result = Hosts()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: endpoint.socketDirectory)) ?? []
        where SessionHost.isEndpointName(name) {
            guard let paths = try? SessionHost.paths(socketDirectory: endpoint.socketDirectory, endpoint: name),
                  let pid = publishedHost(pidfile: paths.pidfile) else { continue }
            result.pids[name] = pid
        }
        result.current = HelperEndpointKey.shared.key(helper: ZmxLaunch.sessionHostPath).flatMap { try? SessionHost.endpointName(key: $0) }
        return result
    }

    /// publishedHost is the pidfile's pid when that process started no later than the file was last written.
    /// A host writes the file after it starts and touches it while it runs, so a pid reused after a host crash
    /// started later. The executable path is no test: an update deletes or moves the old host's image.
    static func publishedHost(pidfile: String) -> pid_t? {
        let fd = open(pidfile, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = read(fd, &bytes, bytes.count)
        guard fstat(fd, &status) == 0, count > 0,
              let pid = pid_t(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
        let written = Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9
        return started <= written ? pid : nil
    }
}

/// HelperEndpointKey runs the bundled helper's `key` once per helper file, keyed by device, inode and
/// modification time because an update replaces the file under the running app. A failed run is not cached.
final class HelperEndpointKey: Sendable {
    static let shared = HelperEndpointKey()

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
        let modified: Int
    }

    private let cache = OSAllocatedUnfairLock<[String: (identity: FileIdentity, key: String)]>(initialState: [:])
    private let run: @Sendable (String) -> String?

    init(run: @escaping @Sendable (String) -> String? = HelperEndpointKey.runHelper) {
        self.run = run
    }

    func key(helper: String) -> String? {
        var status = stat()
        guard stat(helper, &status) == 0 else { return nil }
        let identity = FileIdentity(device: status.st_dev, inode: status.st_ino,
                                    modified: status.st_mtimespec.tv_sec * 1_000_000_000 + status.st_mtimespec.tv_nsec)
        if let cached = cache.withLock({ $0[helper] }), cached.identity == identity { return cached.key }
        guard let key = run(helper), (try? SessionHost.endpointName(key: key)) != nil else { return nil }
        cache.withLock { $0[helper] = (identity, key) }
        return key
    }

    private static func runHelper(_ helper: String) -> String? {
        let invocation = ZmxClient.Invocation(executablePath: helper, arguments: ["key"], environment: [:],
                                              timeout: 2, mergesStderr: false)
        return (try? ZmxClient.run(invocation))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Everything a remote row's panes attach with: what discovery found, or what the row book saved.
struct RemoteRow {
    let host: String
    let endpoint: ControlZmxEndpoint
    let sessionName: String
    let remoteSessionID: String
    let presentationVersion: Int?
    let left: String
    let right: String?
    let splitAxis: SplitAxis?
    /// The name the row is created with. The origin owns it, and its first snapshot corrects a seed that was
    /// only the origin's automatic name.
    let name: String?
    /// A rename made on this Mac, saved before the origin confirmed it; it goes out with the first snapshot.
    let namePending: Bool
    /// The origin reported `headless` in its tree; a restored row does not know and says false.
    var originHeadless = false
    /// The origin's companions of the session when discovered, the baseline its membership is followed from; a
    /// restored row has none.
    var companions: [String]?
    /// The origin session this one is a companion of, nil for a top-level one or a restored row.
    var originParent: String?
}

/// A row's window and workspace, pinned before a remote round trip. `newSessionRule` marks the "+" path.
struct RemoteDestination {
    struct NewSessionRule {
        let selectionAtRequest: UUID?
    }

    let windowID: UUID
    let workspace: UUID
    let newSessionRule: NewSessionRule?
}

/// How a "+" remote create ended. `createdNotAttached` means the session exists on the host with no row here.
enum RemoteCreateOutcome {
    case attached(Session)
    case refused(String)
    case createdNotAttached(remoteID: String, error: String)
}

enum RemoteRowInsert {
    case inserted(Session)
    case refused(ControlResponse)
}
