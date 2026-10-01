import agtermCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The headless origin's model: its window library, its daemons, and the presentation hub its stores feed.
@MainActor
public final class Headless {
    let config: HeadlessConfig
    let library: WindowLibrary
    let runner: any ZmxRunning
    static let programVersion = "headless"
    static let commandTimeout: TimeInterval = 5
    let hub = PresentationHub(staleTimeout: 30)
    private let shellLookup: () -> String?
    private let streams: any HeadlessStreams

    public init(config: HeadlessConfig, runner: (any ZmxRunning)? = nil, shellLookup: (() -> String?)? = nil,
                streams makeStreams: (WindowLibrary, PresentationHub) -> any HeadlessStreams) {
        self.config = config
        self.shellLookup = shellLookup ?? { Self.passwordDatabaseShell() }
        self.runner = runner ?? ProcessZmxRunner(executable: config.zmxExecutable, zmxDirectory: config.zmxDirectory)
        try? FileManager.default.createDirectory(atPath: config.zmxDirectory, withIntermediateDirectories: true)
        library = WindowLibrary(directory: URL(fileURLWithPath: config.stateDirectory))
        streams = makeStreams(library, hub)
        for entry in library.windows {
            guard let store = library.store(for: entry.id) else { continue }
            store.presentationHub = hub
            store.workspaces.flatMap(\.sessions).forEach(attachSurfaces)
        }
        attachAskPresentation()
        attachSeenPresentation()
    }

    private func attachSeenPresentation() {
        hub.onSeen = { [weak self] id in
            guard let (store, session) = self?.resolve(id.uuidString) else { return }
            HeadlessActions.markSessionSeen(session, in: store)
        }
    }

    private func attachAskPresentation() {
        let library = library
        AskRegistry.shared.resolveOwner = { [weak library] owner in
            switch owner {
            case .window: return nil
            case .session(let id, let window): return library?.store(for: window)?.session(withID: id)?.askPending
            }
        }
        hub.onPresenterChanged = { [weak self] id in
            self?.library.store(forSession: id)?.reofferRemoteAsk(forSession: id, includeWaiting: true)
        }
        hub.onPresenterWillChange = { [weak self] id in
            guard let self, let session = self.library.store(forSession: id)?.session(withID: id),
                  let ask = session.askPending, let owner = session.askRemoteOwner else { return }
            self.hub.sendToPresenter(.askDismiss(PresentationAskRef(id: ask.id, owner: owner)), session: id)
        }
        hub.onPresenterLost = { [weak self] id in
            self?.library.store(forSession: id)?.session(withID: id)?.takeAskBack()
        }
        hub.onPresenterFrame = { [weak self] id, body in
            guard let store = self?.library.store(forSession: id) else { return }
            switch body {
            case .askResolve(let answer): store.resolveRemoteAsk(answer, forSession: id)
            case .askRejected(let ref) where store.isPresentingRemotely(ref, forSession: id):
                store.failHandback(forSession: id)
            default: break
            }
        }
    }

    private static func passwordDatabaseShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    private func attachSurfaces(_ session: Session) {
        session.surface = DaemonSurface(paneIdentity: session.paneIdentity)
        if session.hasSplit, let split = session.splitPaneIdentity {
            session.splitSurface = DaemonSurface(paneIdentity: split)
        }
    }

    func notFound(_ target: String?) -> ControlResponse {
        guard let target, target != "active" else {
            return ControlResponse(ok: false, error: "a headless origin has no active session; pass --target \"$AGTERM_SESSION_ID\"")
        }
        return ControlResponse(ok: false, error: "no such session: \(target)")
    }

    /// By full id only: the spike has no `active` session to fall back on.
    func resolve(_ target: String?) -> (AppStore, Session)? {
        guard let id = target.flatMap(UUID.init(uuidString:)), let store = library.store(forSession: id),
              let session = store.session(withID: id) else { return nil }
        return (store, session)
    }

    func presentationResponse(_ target: String?) -> ControlResponse {
        guard let (_, session) = resolve(target) else { return notFound(target) }
        guard session.allPanesBackedByZmx else {
            return ControlResponse(ok: false, error: "session is not live-backed, so nothing can be attached to it")
        }
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    /// The adapter writes the ok reply before starting the presentation stream.
    func openPresentation(_ target: String?, fd: Int32) -> ControlResponse? {
        let response = presentationResponse(target)
        guard response.ok, let id = response.result?.id.flatMap(UUID.init(uuidString:)) else { return response }
        return streams.adopt(session: id, fd: fd)
    }

    var primaryStore: AppStore? { library.windows.first.flatMap { library.store(for: $0.id) } }

    func inventory(observed: [ZmxSessionRecord]) -> ControlZmxInventory {
        let walk = library.paneClaims()
        return ControlZmxInventory(
            restore: ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live, unavailableReason: nil),
            result: ZmxInventory.join(observed: observed, claims: walk.claims, inventoryComplete: walk.complete),
            socketDirectory: config.zmxDirectory, endpoint: config.endpoint)
    }

    /// The same join the Mac's `localAttachableSessions` does, over a library whose panes are all daemons.
    func attachableSessions(inventory: ControlZmxInventory) -> ControlResponse {
        let windows = library.windows.compactMap { entry in
            library.store(for: entry.id).map {
                RemoteWindowProjection(id: entry.id.uuidString, name: entry.name,
                                       tree: $0.controlTree(paneForeground: { _ in nil }))
            }
        }
        do {
            return ControlResponse(ok: true, result: ControlResult(
                remote: try RemoteTreeMerger.candidates(windows: windows, inventory: inventory)))
        } catch {
            return ControlResponse(ok: false, error: "the session list could not be built: \(error)")
        }
    }

    /// A session whose left pane is a fresh daemon; zmx types `/bin/sh -c command` into its login shell.
    func newSession(name: String?, command: String?, cwd: String?) -> ControlResponse {
        let requestedDirectory = cwd ?? NSHomeDirectory()
        guard !requestedDirectory.isEmpty, TerminalText.sanitized(requestedDirectory) == requestedDirectory else {
            return ControlResponse(ok: false, error: "session.new requires an existing working directory")
        }
        let directory = URL(fileURLWithPath: requestedDirectory).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ControlResponse(ok: false, error: "session.new requires an existing working directory")
        }
        let command = command ?? "true"
        guard let store = primaryStore, let workspace = store.currentWorkspaceID ?? store.workspaces.first?.id else {
            return ControlResponse(ok: false, error: "no window")
        }
        guard let session = store.addSession(toWorkspace: workspace, cwd: directory, name: name) else {
            return ControlResponse(ok: false, error: "could not create the session")
        }
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let environment = paneEnvironment(for: session, in: store, pane: .left, identity: session.paneIdentity)
        guard zmx(["run", daemon, "-d", "sh", "-c", command], environment: environment, workingDirectory: directory) != nil else {
            // zmx may have created the daemon before failing; an unclaimed one would outlive the session
            _ = zmx(["kill", daemon, "--force"])
            store.closeSession(session.id)
            return ControlResponse(ok: false, error: "zmx could not create \(daemon)")
        }
        attachSurfaces(session)
        store.presentationHub = hub
        store.save()
        library.saveIndex()
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    private func paneEnvironment(for session: Session, in store: AppStore, pane: StatusPane, identity: UUID) -> [String: String] {
        var environment = SurfaceEnvironment.session(sessionID: session.id, windowID: library.windowID(for: store),
                                                     workspaceID: store.workspace(forSession: session.id)?.id, socketPath: config.socketPath,
                                                     programVersion: Self.programVersion, pane: pane, paneToken: identity.uuidString)
        environment["AGTERM_STATE_DIR"] = config.stateDirectory
        let shell = shellLookup()
        environment["SHELL"] = shell?.isEmpty == false ? shell : "/bin/sh"
        return environment
    }

    func splitSession(_ session: Session, in store: AppStore, mode: String?, axis: SplitAxis?, command: ControlSplitCommand?) -> ControlResponse {
        guard let mode = ControlToggleMode.parse(mode) else {
            return ControlResponse(ok: false, error: "invalid split mode: \(mode ?? "toggle")")
        }
        if command != nil {
            guard mode == .on else { return ControlResponse(ok: false, error: "--command needs mode on") }
            guard !session.hasSplit else {
                return ControlResponse(ok: false, error: "split already running; session split close first")
            }
        }
        let shown: Bool
        switch mode {
        case .on: shown = true
        case .off: shown = false
        case .toggle: shown = axis.map { !session.isSplit || session.splitAxis != $0 } ?? !session.isSplit
        }
        if shown, !session.hasSplit {
            let identity = UUID()
            let daemon = ZmxSupport.daemonName(for: identity)
            let directory = session.effectiveCwd
            let environment = paneEnvironment(for: session, in: store, pane: .right, identity: identity)
            guard zmx(["run", daemon, "-d", "sh", "-c", command?.command ?? "true"],
                      environment: environment, workingDirectory: directory) != nil else {
                _ = zmx(["kill", daemon, "--force"])
                return ControlResponse(ok: false, error: "zmx could not create \(daemon)")
            }
            // Publish only after spawn; setSplitVisibility must keep the identity handed to the daemon.
            session.hasSplit = true
            session.splitPaneIdentity = identity
            session.splitSurface = DaemonSurface(paneIdentity: identity)
            session.initialSplitCwd = directory
            session.splitInitialCommand = command?.command
            session.splitCommandWait = command?.wait ?? false
            session.splitFocused = true
        }
        store.setSplitVisibility(session.id, shown: shown, axis: axis)
        persist(store)
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    /// Kills every pane's daemon, then closes the session. A failed kill does not keep the session: the model is
    /// the only claim on the daemon, so a survivor shows in `zmx list` as unclaimed.
    func closeSession(_ session: Session, in store: AppStore) {
        for pane in [session.paneIdentity] + [session.splitPaneIdentity].compactMap({ $0 }) {
            _ = zmx(["kill", ZmxSupport.daemonName(for: pane), "--force"])
        }
        store.closeSession(session.id)
        persist(store)
        streams.closeStreams(session: session.id)
    }

    /// Kills one pane's daemon and closes that pane as its exit would; a failed kill changes nothing.
    func killPane(_ pane: ZmxPaneRole, of session: Session, in store: AppStore) -> ControlResponse {
        let identity = pane == .left ? session.paneIdentity : session.hasSplit ? session.splitPaneIdentity : nil
        guard let identity else {
            return ControlResponse(ok: false, error: "no \(pane.rawValue) pane daemon for session \(session.id.uuidString)")
        }
        let daemon = ZmxSupport.daemonName(for: identity)
        guard zmx(["kill", daemon, "--force"]) != nil else {
            return ControlResponse(ok: false, error: "could not kill \(daemon)")
        }
        paneExited(pane, of: session, in: store)
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, text: "killed \(daemon)",
                                                               pane: pane.rawValue))
    }

    /// Closes one pane whose daemon is gone: the split collapses, a primary with a split promotes it, and a lone
    /// primary closes the session.
    func paneExited(_ pane: ZmxPaneRole, of session: Session, in store: AppStore) {
        switch pane {
        case .right:
            store.closeSplit(session.id)
        case .left where session.hasSplit:
            store.closePrimaryPane(session.id)
        case .left:
            store.closeSession(session.id)
            streams.closeStreams(session: session.id)
        }
        persist(store)
    }

    func persist(_ store: AppStore) {
        store.save()
        library.saveIndex()
    }

    /// One zmx invocation against this origin's own socket directory; nil when it failed.
    func zmx(_ arguments: [String], environment: [String: String] = [:], workingDirectory: String? = nil) -> String? {
        guard case .ok(let output) = runner.run(arguments, environment: environment, workingDirectory: workingDirectory,
                                               timeout: Self.commandTimeout) else { return nil }
        return output
    }
}
