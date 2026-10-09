import AppKit
import OSLog
import agtermCore

/// What the host does to IDE windows; `RebasedFrameKeeper` in the app, a recorder in tests.
@MainActor
protocol RebasedFrames: AnyObject {
    func adopt(_ frame: NSWindow, in host: NSWindow?)
    func attach(_ window: NSWindow, to host: NSWindow?)
    func detach(_ window: NSWindow)
    func orderOut(_ window: NSWindow)
    func refit(host: NSWindow)
    func makeKey(_ frame: NSWindow)
}

struct RebasedOpened: Equatable {
    let overlay: UUID
    var request: String?
}

struct RebasedOpenRefusal: Error, Equatable {
    let message: String
}

/// Owns the embedded Rebased JVM and maps its project frames onto session overlays; the single owner, like
/// `HtmlOverlayRegistry`. The JVM, once created, lives as long as the process: HotSpot cannot start twice.
@MainActor @Observable
final class RebasedHost {
    static var shared = RebasedHost()
    static let readyDeadline: TimeInterval = 30
    static let deadlineMessage = "Rebased did not start within 30 s"

    enum JVM: Equatable {
        case notStarted, starting, running, failed(String)
    }

    struct Entry {
        let id: UUID
        let session: UUID
        let project: String
        let order: Int
        let onClose: RebasedOnClose?
    }

    struct RemoteOpenRequest {
        let path: String
        let sizePercent: Int?
        let view: RebasedView?
        let pane: OverlayPane?
    }

    var runtime: any RebasedRuntime = JNIRebasedRuntime()
    var frames: any RebasedFrames = RebasedFrameKeeper()
    var keymap: () -> Keymap = { Keymap(builtinOverrides: [:], commands: []) }
    var toggle: (UUID?) -> Void = { _ in }
    var appPath: () -> String = { "/Applications/Rebased.app" }
    var stateDirectory = PersistenceStore.defaultDirectory
    var store: (UUID) -> AppStore? = { _ in nil }
    var hostWindow: (UUID) -> NSWindow? = { _ in nil }
    var window: (Int) -> NSWindow? = { NSApp.window(withWindowNumber: $0) }
    var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }
    var offMain: (@escaping @Sendable () -> Void, @escaping @MainActor @Sendable () -> Void) -> Void = { work, done in
        Task.detached(priority: .userInitiated) {
            work()
            await done()
        }
    }
    /// Every job that writes under `mirrors/` runs here, one at a time. Nothing on the main actor may wait on it:
    /// a prune job reads its `mirrorsInUse` snapshot from main.
    var onMirrorQueue: (@escaping @Sendable () -> Void, @escaping @MainActor @Sendable () -> Void) -> Void = { work, done in
        let body: @Sendable () -> Void = {
            work()
            Task { @MainActor in done() }
        }
        RebasedHost.mirrorQueue.async(execute: body)
    }
    var isIDEKeyWindowOverride: Bool?
    var isFocusedPane: (UUID, OverlayPane) -> Bool = { _, _ in false }
    var clock: () -> Date = { Date() }
    var mirrorRefresh: @Sendable (RebasedMirror, URL) -> Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure> =
        RebasedHost.makeMirrorRefresh(withLock: { try RebasedStateLock.withLockIfFree($0, $1) })
    // The defaults touch no disk; only `configure` installs the real ones, so a test's host never prunes.
    var mirrorMaxAgeDays: () -> Int = { 0 }
    var mirrorPrune: @Sendable (RebasedMirrorCleanup.Request) throws -> RebasedMirrorCleanup.Report = { request in
        RebasedMirrorCleanup.Report(removed: [], kept: [], dryRun: request.dryRun, olderThanDays: request.maxAgeDays)
    }
    var mirrorList: @Sendable (URL, Set<String>) -> [RebasedMirrorRecord] = { _, _ in [] }
    private nonisolated static let mirrorQueue = DispatchQueue(label: "com.umputun.agterm.rebased.mirrors")
    private static let touchInterval: TimeInterval = 3600
    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "RebasedHost")

    private(set) var jvm = JVM.notStarted
    var entries: [UUID: Entry] = [:]
    // overlays whose local open on a mirror's clone waits for the mirror queue
    private var pendingMirrorOpens: [UUID: String] = [:]
    private var frameNumbers: [String: Int] = [:]
    // a project closed in the IDE can still have state this JVM run writes back under `system/`
    private var openedThisRun: Set<String> = []
    // in memory only, keyed by canonical project: the first show after a relaunch touches again
    private var lastTouched: [String: Date] = [:]
    private(set) var visible: [String: UUID] = [:]
    // a slot is hidden until its view reports it on screen, so no path can show a frame over another session
    private var visibleSlots: Set<UUID> = []
    private var visibilityReports: [UUID: Set<UUID>] = [:]
    private var needsInitialFocus: Set<UUID> = []
    private var saving = false
    var environment: (Session, AppStore) -> [String: String] = { _, _ in ProcessInfo.processInfo.environment }
    var runOnClose: (RebasedOnClose) -> Void = { RebasedOnCloseRunner.run($0) }
    var now: () -> Date = Date.init
    var idePort: Int?
    var portLookup: UUID?
    // keyed by overlay id: a released overlay's dialogs must never replay over the session's next project
    private var pendingDialogs: [UUID: [NSWindow]] = [:]
    // sessions whose mirror is being refreshed; a second open would race the same git directory
    var fetching: Set<UUID> = []
    private var slots: [UUID: NSRect] = [:]
    private var lastShown: UUID?
    private var lastShownByProject: [String: UUID] = [:]
    // each overlay's running start deadline; a pre-frame dialog drops it and its close arms a new one
    private var deadlines: [UUID: UUID] = [:]
    private var dialogCloses: [UUID: NSObjectProtocol] = [:]
    private var prepared = false
    private var bound = false
    private var deadlinePassed = false
    private var opens = 0
    // One per process: it serves `RebasedHost.shared`, and a test host per case would otherwise stack one
    // observer each, every one scanning every window on every run-loop pass.
    private static var bornObserver: CFRunLoopObserver?
    private static var keyObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var seenWindows: Set<Int> = []

    func configure(library: WindowLibrary, settings: @escaping () -> AppSettings, stateDirectory: URL,
                   keymap: @escaping () -> Keymap, toggle: @escaping (UUID?) -> Void) {
        appPath = { settings().effectiveRebasedAppPath }
        self.keymap = keymap
        self.toggle = toggle
        self.stateDirectory = stateDirectory
        mirrorMaxAgeDays = { settings().effectiveRebasedMirrorMaxAgeDays }
        mirrorPrune = Self.makeMirrorPrune(withLock: RebasedStateLock.withLockIfFree)
        mirrorList = Self.makeMirrorList()
        isFocusedPane = { [weak library] id, pane in
            guard let store = library?.activeStore else { return false }
            return store.selectedSessionID == id && store.session(withID: id)?.focusedPane == pane
        }
        store = { [weak library] in library?.store(forSession: $0) }
        hostWindow = { [weak library] session in
            library?.windowID(forSession: session).flatMap { WindowRegistry.shared.window(for: $0) }
        }
        install()
    }

    func install() {
        (frames as? RebasedFrameKeeper)?.slotRect = { [weak self] frame in
            self?.slotRect(for: frame) ?? frame.frame
        }
        RebasedOverlayReleases.shared.onRelease = { [weak self] in self?.release($0) }
    }

    var isIDEKeyWindow: Bool {
        isIDEKeyWindowOverride ?? keyWindow().map(Self.isIDEWindow) ?? false
    }

    static func isIDEWindow(_ window: NSWindow) -> Bool { window.className.hasPrefix("AWT") }

    var status: ControlRebasedNode {
        let projects = frameNumbers.keys.sorted()
        switch jvm {
        case .notStarted: return .init(jvm: "notStarted")
        case .starting: return .init(jvm: "starting", projects: projects)
        case .running: return .init(jvm: "running", projects: projects, port: idePort)
        case .failed(let error): return .init(jvm: "failed", error: error, projects: projects)
        }
    }

    /// The overlay's frame is shown in this session, as opposed to waiting or shown in another session.
    func isShown(in session: UUID) -> Bool {
        visible.values.contains { entries[$0]?.session == session }
    }

    // MARK: - Opening

    func openOverlay(in store: AppStore, session id: UUID, cwd: String?, sizePercent: Int?, view: RebasedView? = nil,
                     pane: OverlayPane? = nil, project: String? = nil, onClose: String? = nil) -> Result<RebasedOpened, RebasedOpenRefusal> {
        guard let session = store.session(withID: id) else {
            return .failure(.init(message: RebasedOverlayOpenFailure.unknownSession.message))
        }
        if onClose != nil, session.rebasedPlacement != nil {
            return .failure(.init(message: "a Rebased overlay is already open in this session; --on-close needs a new one"))
        }
        if session.remoteHost != nil, onClose != nil { return .failure(.init(message: "--on-close works on a local row only")) }
        let captured = onClose.map { RebasedOnClose(command: $0, cwd: cwd ?? onCloseDirectory(for: session), environment: environment(session, store)) }
        if session.remoteHost != nil {
            return openRemote(in: store, session: session,
                              request: .init(path: cwd ?? session.focusedCwd, sizePercent: sizePercent, view: view, pane: pane))
        }
        let project = project ?? Self.projectDirectory(for: cwd ?? session.focusedCwd)
        if let placement = session.rebasedPlacement, Self.canonical(placement.overlay.project) == Self.canonical(project) {
            guard pane == nil || placement.pane == pane else {
                return .failure(.init(message: RebasedOverlayOpenFailure.alreadyOpen.message))
            }
            let request = view.map { requestView(overlay: placement.overlay.id, view: $0) }
            return .success(.init(overlay: placement.overlay.id, request: request))
        }
        var overlay = RebasedOverlay(project: project, view: view.map(RebasedViewRequest.init(view:)), onClose: captured)
        if case .diff(let diff, _) = view { overlay.diff = diff }
        if let failure = store.openRebasedOverlay(id, overlay: overlay, sizePercent: sizePercent, pane: pane) {
            return .failure(.init(message: failure.message(pane: pane)))
        }
        if Self.isMirror(project, stateDirectory: stateDirectory) {
            openAfterMirrorJobs(session: id, overlay: overlay.id, project: project)
        } else {
            open(session: id)
        }
        return .success(.init(overlay: overlay.id, request: overlay.view?.id))
    }

    /// A local overlay on a mirror's clone waits for any prune queued ahead of it, and a prune queued after it keeps
    /// the clone through `pendingMirrorOpens`; a clone that prune removed fails the overlay rather than opening nothing.
    private func openAfterMirrorJobs(session id: UUID, overlay overlayID: UUID, project: String) {
        pendingMirrorOpens[overlayID] = Self.canonical(project)
        onMirrorQueue({}, { [weak self] in
            guard let self, pendingMirrorOpens.removeValue(forKey: overlayID) != nil,
                  let session = store(id)?.session(withID: id), session.rebasedPlacement?.overlay.id == overlayID else { return }
            if FileManager.default.fileExists(atPath: project) {
                open(session: id)
            } else {
                // no entry exists before `open`, so `setState` would find nothing to fail
                session.updateRebasedOverlay(overlayID) { $0.state = .failed("Rebased mirror \(project) was removed by a prune") }
            }
        })
    }

    private static func isMirror(_ project: String, stateDirectory: URL) -> Bool {
        let mirrors = canonical(stateDirectory.appendingPathComponent("rebased/mirrors", isDirectory: true).path)
        return canonical(project).hasPrefix(mirrors + "/")
    }

    // MARK: - Remote rows

    func openRemote(in store: AppStore, session: Session, request: RemoteOpenRequest) -> Result<RebasedOpened, RebasedOpenRefusal> {
        let path = request.path, sizePercent = request.sizePercent, view = request.view, pane = request.pane
        let host = session.remoteHost ?? ""
        guard let mirror = RebasedMirror(host: host, path: path) else {
            return .failure(.init(message: "Rebased cannot mirror \(host):\(path)"))
        }
        if let refusal = fetchRefusal(session: session) { return .failure(.init(message: refusal)) }
        let overlayID: UUID
        let request: String?
        if let placement = session.rebasedPlacement {
            guard pane == nil || placement.pane == pane, let source = placement.overlay.source,
                  RebasedMirror.covers(source: source, host: host, path: path) else {
                return .failure(.init(message: RebasedOverlayOpenFailure.alreadyOpen.message))
            }
            overlayID = placement.overlay.id
            request = view.map { issueView(overlay: overlayID, view: $0) }
        } else {
            var placeholder = RebasedOverlay(project: path, state: .fetching, source: mirror.source(top: path),
                                             view: view.map(RebasedViewRequest.init(view:)))
            if case .diff(let diff, _) = view { placeholder.diff = diff }
            if let failure = store.openRebasedOverlay(session.id, overlay: placeholder, sizePercent: sizePercent, pane: pane) {
                return .failure(.init(message: failure.message(pane: pane)))
            }
            overlayID = placeholder.id
            request = placeholder.view?.id
            opens += 1
            entries[overlayID] = Entry(id: overlayID, session: session.id, project: Self.canonical(path), order: opens, onClose: placeholder.onClose)
        }
        fetching.insert(session.id)
        let refresh = mirrorRefresh, directory = stateDirectory, sessionID = session.id
        let result = ResultBox<RebasedMirrorRefresh.Copy>()
        onMirrorQueue({ result.set { try refresh(mirror, directory).get() } }, { [weak self] in
            self?.mirrored(result.value, session: sessionID, overlay: overlayID, request: request)
        })
        return .success(.init(overlay: overlayID, request: request))
    }

    private func mirrored(_ result: Result<RebasedMirrorRefresh.Copy, any Error>?, session sessionID: UUID, overlay overlayID: UUID,
                          request: String?) {
        fetching.remove(sessionID)
        guard let session = store(sessionID)?.session(withID: sessionID), let current = session.rebasedPlacement?.overlay,
              current.id == overlayID else { return }
        switch (result, current.state == .fetching) {
        case (.success(let copy)?, true):
            session.updateRebasedOverlay(overlayID) {
                $0.project = copy.directory
                $0.source = copy.source
                $0.state = .starting
            }
            open(session: sessionID)
        case (.success?, false):
            if request == current.view?.id { sendView(overlay: overlayID) }
        case (.failure(let error)?, let placeholder):
            let message = (error as? RebasedMirrorRefresh.Failure)?.message ?? error.localizedDescription
            if placeholder { session.updateRebasedOverlay(overlayID) { $0.state = .failed(message) } }
            if let request { failView(overlay: overlayID, request: request, reason: message) }
            Self.logger.error("\(message, privacy: .public)")
        case (nil, _): break
        }
    }

    func open(session: UUID) {
        guard let model = store(session)?.session(withID: session), let overlay = model.rebasedPlacement?.overlay else { return }
        opens += 1
        let project = Self.canonical(overlay.project)
        entries[overlay.id] = Entry(id: overlay.id, session: session, project: project, order: opens, onClose: overlay.onClose)
        if let pane = model.rebasedPlacement?.pane, isFocusedPane(session, pane) { needsInitialFocus.insert(overlay.id) }
        switch jvm {
        case .running:
            if frameNumbers[project] != nil { show(overlay: overlay.id) } else { _ = runtime.call("open", project) }
            armDeadline(overlay.id)
        case .starting:
            if prepared { armDeadline(overlay.id) }
        case .notStarted:
            start()
        case .failed(let error):
            if runtime.jvmCreated { setState(.failed(error), overlay: overlay.id) } else { start() }
        }
    }

    // The deadline starts once the plugin is built, ahead of `launch`, which can block without bound; a late
    // launch still binds and its `ready` serves the next open.
    private func start() {
        jvm = .starting
        prepared = false
        bound = false
        deadlinePassed = false
        installBornObserver()
        installKeyRouter()
        installKeyObserver()
        let runtime = runtime, path = appPath(), directory = stateDirectory
        let result = ResultBox<RebasedLaunch>()
        offMain({ result.set { try runtime.prepare(appPath: path, stateDirectory: directory) } }, { [weak self] in
            guard let self else { return }
            switch result.value {
            case .success(let launch):
                pruneThenLaunch(launch)
            case .failure(let error):
                fail(error.localizedDescription)
            case nil:
                break
            }
        })
    }

    // The prune runs before `launch`, so no project an old IDE config reopens can be a mirror being deleted, and
    // before the deadline is armed, so the 30 s never count it. Behind another row's fetch it would hold the start.
    private func pruneThenLaunch(_ launch: RebasedLaunch) {
        let ready: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            prepared = true
            for (id, entry) in entries where overlayState(entry) == .starting { armDeadline(id) }
            self.launch(launch)
        }
        let days = mirrorMaxAgeDays()
        guard days > 0, fetching.isEmpty else { return ready() }
        let prune = mirrorPrune, directory = stateDirectory
        let result = ResultBox<RebasedMirrorCleanup.Report>()
        onMirrorQueue({ [self] in
            let inUse = Self.inUseSnapshot(self)
            result.set { try prune(.init(stateDirectory: directory, inUse: inUse, maxAgeDays: days, dryRun: false)) }
        }, {
            switch result.value {
            case .success(let report)?: Self.logger.info("Rebased start prune removed \(report.removed.count) mirrors")
            case .failure(let error)?: Self.logger.error("Rebased start prune failed: \(error.localizedDescription, privacy: .public)")
            case nil: break
            }
            ready()
        })
    }

    private func launch(_ launch: RebasedLaunch) {
        let runtime = runtime
        let result = ResultBox<Void>()
        offMain({ result.set { try runtime.launch(launch) } }, { [weak self] in
            guard let self else { return }
            if case .failure(let error) = result.value { fail(error.localizedDescription) } else { bind() }
        })
    }

    private func bind() {
        guard jvm == .starting, !bound else { return }
        switch runtime.bindEvents() {
        case nil:
            bound = true
        case .notReady?:
            after(deadlinePassed ? 2 : 0.25) { [weak self] in self?.bind() }
        case .failed(let message)?:
            fail(message)
        }
    }

    private func armDeadline(_ id: UUID) {
        guard deadlines[id] == nil else { return }
        let token = UUID()
        deadlines[id] = token
        after(Self.readyDeadline) { [weak self] in
            guard let self, deadlines[id] == token else { return }
            deadlines[id] = nil
            if jvm == .starting { deadlinePassed = true }
            guard let entry = entries[id], overlayState(entry) == .starting else { return }
            setState(.failed(Self.deadlineMessage), overlay: entry.id)
        }
    }

    // The user may take any time to answer, so the 30 s start again only once the dialog closes.
    private func pauseDeadline(_ id: UUID, until dialog: NSWindow) {
        guard deadlines.removeValue(forKey: id) != nil, dialogCloses[id] == nil else { return }
        dialogCloses[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: dialog,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let token = self.dialogCloses.removeValue(forKey: id) else { return }
                NotificationCenter.default.removeObserver(token)
                if self.entries[id] != nil { self.armDeadline(id) }
            }
        }
    }

    private func fail(_ message: String) {
        jvm = .failed(message)
        for entry in entries.values where overlayState(entry) == .starting {
            setState(.failed(message), overlay: entry.id)
        }
    }

    // MARK: - Events

    // A project path can hold a tab, so it is always the field split off last.
    func handle(event kind: String, payload: String) {
        switch kind {
        case "ready":
            jvm = .running
            deadlinePassed = false
            let waiting = entries.values.filter { overlayState($0) == .starting }
            for project in Set(waiting.map(\.project)) where frameNumbers[project] == nil {
                _ = runtime.call("open", project)
            }
        case "frameOpened":
            guard let tab = payload.lastIndex(of: "\t"), let number = Int(payload[payload.index(after: tab)...]) else { return }
            frameOpened(project: Self.canonical(String(payload[..<tab])), number: number)
        case "frameClosed":
            frameClosed(project: Self.canonical(payload))
        case "windowOpened":
            let fields = payload.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let number = Int(fields[0]), let window = window(number) else { return }
            let owner = fields.count > 2 && !fields[2].isEmpty ? Self.canonical(fields[2]) : nil
            windowOpened(window, kind: fields[1], owner: owner)
        case "viewOpened", "viewFailed":
            handleViewEvent(kind: kind, payload: payload)
        case "failed":
            fail(payload)
        default:
            break
        }
    }

    // A frame that arrives after its overlays failed stays hidden for the next open instead of reviving them.
    private func frameOpened(project: String, number: Int) {
        frameNumbers[project] = number
        openedThisRun.insert(project)
        beginPortLookup()
        let waiting = entries.values.filter { $0.project == project && overlayState($0) == .starting }
        for entry in waiting { setState(.shown, overlay: entry.id) }
        let onScreen = waiting.filter { visibleSlots.contains($0.id) }
        guard let latest = onScreen.max(by: { $0.order < $1.order }) else {
            if visible[project] == nil { _ = runtime.call("hide", project) }
            return
        }
        show(overlay: latest.id)
    }

    private func frameClosed(project: String) {
        frameNumbers[project] = nil
        visible[project] = nil
        let closing = entries.values.filter { $0.project == project }
        for entry in closing { _ = store(entry.session)?.closeRebasedOverlay(entry.session, id: entry.id) }
    }

    private func windowOpened(_ window: NSWindow, kind: String, owner: String?) {
        if kind == "welcome" { return frames.orderOut(window) }
        // the born observer hid it as a possible project frame; only the keeper reveals those
        window.alphaValue = 1
        if let owner, let id = visible[owner], let entry = entries[id] {
            frames.attach(window, to: hostWindow(entry.session))
        } else if kind == "dialog", let (id, waiting) = waiting(owner) {
            // IntelliJ can ask before any frame exists ("Trust project?"); it belongs to the slot being opened
            pauseDeadline(id, until: window)
            if visibleSlots.contains(waiting.id) {
                frames.attach(window, to: hostWindow(waiting.session))
            } else {
                frames.orderOut(window)
                pendingDialogs[id, default: []].append(window)
            }
        } else if owner == nil, let id = lastShown.flatMap({ visible.values.contains($0) ? $0 : nil }) ?? visible.values.first,
                  let entry = entries[id] {
            frames.attach(window, to: hostWindow(entry.session))
        } else if kind == "dialog", let last = owner.map({ lastShownByProject[$0] }) ?? lastShown,
                  let current = entries[last], owner == nil || current.project == owner {
            reveal(session: current.session, dialog: window)
        } else {
            frames.orderOut(window)
        }
    }

    // The opening overlay a frameless dialog belongs to, the one on screen first, then the newest.
    private func waiting(_ project: String?) -> (UUID, Entry)? {
        entries.filter { (project == nil || $0.value.project == project) && overlayState($0.value) == .starting }
            .max { lhs, rhs in
                let left = visibleSlots.contains(lhs.key), right = visibleSlots.contains(rhs.key)
                return left == right ? lhs.value.order < rhs.value.order : !left
            }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Visibility

    /// A ready frame marks the overlay shown at once; the frame itself moves onto the slot only while the
    /// slot's view reports it on screen.
    func show(session: UUID) {
        guard let id = overlayID(for: session) else { return }
        show(overlay: id)
    }

    func show(overlay id: UUID, focusIfFocusedPane: Bool = false) {
        guard let entry = entries[id], let number = frameNumbers[entry.project], let frame = window(number) else { return }
        if case .failed = overlayState(entry) { return }
        guard overlay(entry)?.hidden != true, overlayState(entry) != .fetching else { return }
        // Armed only while the pane has the keyboard, so a later switch back to the session never takes it.
        if focusIfFocusedPane, visible[entry.project] != id,
           let pane = store(entry.session)?.session(withID: entry.session)?.rebasedPlacement?.pane,
           isFocusedPane(entry.session, pane) { needsInitialFocus.insert(id) }
        setState(.shown, overlay: id)
        guard visibleSlots.contains(id) else { return }
        visible[entry.project] = id
        lastShown = id
        lastShownByProject[entry.project] = id
        _ = runtime.call("show", entry.project)
        frames.adopt(frame, in: hostWindow(entry.session))
        sendView(overlay: id)
        touchMirror(project: entry.project, session: entry.session)
        if needsInitialFocus.remove(id) != nil,
           let pane = store(entry.session)?.session(withID: entry.session)?.rebasedPlacement?.pane,
           isFocusedPane(entry.session, pane) { focus(overlay: id) }
    }

    // An overlay only shown and hidden for weeks would otherwise keep a marker as old as its last refresh, and the
    // first prune after it closes would delete a mirror in daily use. Cheapest checks first.
    private func touchMirror(project: String, session: UUID) {
        guard let source = store(session)?.session(withID: session)?.rebasedPlacement?.overlay.source else { return }
        let now = clock()
        if let last = lastTouched[project], now.timeIntervalSince(last) < Self.touchInterval { return }
        guard let hash = RebasedMirrorCleanup.hashDirectory(ofClone: URL(fileURLWithPath: project), stateDirectory: stateDirectory)
        else { return }
        lastTouched[project] = now
        onMirrorQueue({ RebasedMirrorMarker.touch(hashDirectory: hash, source: source, now: now) }, {})
    }

    // A click into a pane IDE makes it key without passing through the deck, which is what moves pane focus.
    func ideBecameKey(_ window: NSWindow) {
        guard let id = owner(of: window), let session = store(id)?.session(withID: id),
              let pane = session.rebasedPlacement?.pane else { return }
        session.splitFocused = pane == .right
    }

    // First responder alone leaves the keyboard with the IDE, a child window of the session's.
    func releaseKey(from session: UUID) {
        guard isIDEKeyWindow, let key = keyWindow(), owner(of: key) == session,
              store(session)?.session(withID: session)?.rebasedPlacement?.pane != nil,
              let host = hostWindow(session) else { return }
        frames.makeKey(host)
    }

    @discardableResult
    func focus(overlay id: UUID) -> Bool {
        guard let entry = entries[id], visible[entry.project] == id, overlay(entry)?.hidden != true,
              let number = frameNumbers[entry.project], let frame = window(number) else { return false }
        frames.makeKey(frame)
        return true
    }

    func hide(overlay id: UUID) {
        guard let entry = entries[id] else { return }
        hide(entry)
    }

    func hide(session: UUID) {
        guard let entry = entry(for: session) else { return }
        hide(entry)
    }

    // A dialog usually wants an answer (a credential prompt), so its session comes forward. The slot's own
    // report still decides: under a palette or the dashboard the dialog waits off screen until it clears.
    private func reveal(session: UUID, dialog: NSWindow) {
        store(session)?.selectSession(session)
        hostWindow(session)?.makeKeyAndOrderFront(nil)
        if let id = overlayID(for: session), visibleSlots.contains(id) {
            show(session: session)
            frames.attach(dialog, to: hostWindow(session))
        } else {
            frames.orderOut(dialog)
            if let id = overlayID(for: session) { pendingDialogs[id, default: []].append(dialog) }
        }
    }

    /// The session whose shown frame, or a window attached over it, is `window`.
    func owner(of window: NSWindow) -> UUID? {
        visible.first { project, id in
            guard let entry = entries[id] else { return false }
            return frameNumbers[project].flatMap(self.window) === window
                || (window.parent != nil && window.parent === hostWindow(entry.session))
        }.flatMap { entries[$0.value]?.session }
    }

    func isShownElsewhere(overlay id: UUID) -> Bool {
        guard let entry = entries[id], let holder = visible[entry.project] else { return false }
        return holder != id
    }

    func setSlotVisible(_ isVisible: Bool, session: UUID) {
        guard let id = overlayID(for: session) else { return }
        setSlotVisible(isVisible, overlay: id, reporter: session)
    }

    func setSlotVisible(_ isVisible: Bool, overlay id: UUID, reporter: UUID) {
        let wasVisible = visibleSlots.contains(id)
        if isVisible { visibilityReports[id, default: []].insert(reporter) } else { visibilityReports[id]?.remove(reporter) }
        let nowVisible = visibilityReports[id]?.isEmpty == false
        if nowVisible {
            visibleSlots.insert(id)
        } else {
            visibilityReports[id] = nil
            visibleSlots.remove(id)
        }
        guard nowVisible != wasVisible, let entry = entries[id] else { return }
        if nowVisible {
            show(overlay: id)
            let queued = pendingDialogs.removeValue(forKey: id) ?? []
            for dialog in queued { surface(dialog, session: entry.session) }
        } else {
            hide(entry)
        }
    }

    func setSlot(_ rect: NSRect, overlay id: UUID, in window: NSWindow) {
        guard slots[id] != rect else { return }
        slots[id] = rect
        frames.refit(host: window)
    }

    private func slotRect(for frame: NSWindow) -> NSRect {
        if let project = frameNumbers.first(where: { window($0.value) === frame })?.key,
           let id = visible[project], let rect = slots[id] { return rect }
        return frame.parent.map { $0.convertToScreen($0.contentLayoutRect) } ?? frame.frame
    }

    /// Saves the IDE's unsaved documents before agterm exits, waiting at most `timeout`: the bridge bounds its
    /// own wait, but a JNI call or a stalled disk read is not bounded by it. A JVM that never ran costs
    /// nothing. Returns whether the save answered in time.
    @discardableResult
    func saveBeforeQuit(timeout: TimeInterval = 2) -> Bool {
        guard jvm == .running, !saving else { return false }
        saving = true
        let runtime = runtime
        let done = DispatchSemaphore(value: 0)
        let body: @Sendable () -> Void = {
            _ = runtime.call("saveAll", "")
            done.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: body)
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func hide(_ entry: Entry) {
        guard visible[entry.project] == entry.id else { return }
        visible[entry.project] = nil
        _ = runtime.call("hide", entry.project)
        if let number = frameNumbers[entry.project], let frame = window(number) { frames.detach(frame) }
        handBack(entry)
    }

    // Another slot already on screen for the project would otherwise say "shown in another session" over
    // nothing until its own visibility changed.
    private func handBack(_ previous: Entry) {
        let next = entries.values.filter {
            $0.project == previous.project && $0.id != previous.id && visibleSlots.contains($0.id)
                && overlayState($0) == .shown && overlay($0)?.hidden != true
        }.max { $0.order < $1.order }
        if let next { show(overlay: next.id) }
    }

    // A queued dialog is still blocking the IDE (a modal "Trust project?" holds every project), so short of
    // quit it is never dropped: it comes up over the session now, rather than over whatever that session opens next.
    func removeEntry(_ overlayID: UUID, endingProcess: Bool = false) -> Entry? {
        deadlines[overlayID] = nil
        if let token = dialogCloses.removeValue(forKey: overlayID) { NotificationCenter.default.removeObserver(token) }
        // a mirror open still waiting on the queue has no entry yet
        pendingMirrorOpens[overlayID] = nil
        guard let entry = entries.removeValue(forKey: overlayID) else { return nil }
        visibleSlots.remove(overlayID)
        visibilityReports[overlayID] = nil
        needsInitialFocus.remove(overlayID)
        slots[overlayID] = nil
        let queued = pendingDialogs.removeValue(forKey: overlayID) ?? []
        if endingProcess {
            if visible[entry.project] == entry.id { visible[entry.project] = nil }
        } else {
            hide(entry)
            for dialog in queued { surface(dialog, session: entry.session) }
        }
        if lastShownByProject[entry.project] == entry.id { lastShownByProject[entry.project] = nil }
        return entry
    }

    private func surface(_ dialog: NSWindow, session: UUID) {
        frames.attach(dialog, to: hostWindow(session))
        dialog.orderFront(nil)
    }

    // MARK: - Mirrors

    typealias MirrorLock = @Sendable (URL, () throws -> RebasedMirrorCleanup.Report) throws -> RebasedMirrorCleanup.Report

    /// Projects a prune must keep: open overlays (the pending open included), frames open now, and every frame
    /// this JVM run has opened.
    var mirrorsInUse: Set<String> {
        Set(entries.values.map(\.project)).union(frameNumbers.keys).union(openedThisRun).union(pendingMirrorOpens.values)
    }

    // Read when a prune job starts. The synchronous test seams run the job on main, where `main.sync` would deadlock.
    private nonisolated static func inUseSnapshot(_ host: RebasedHost) -> Set<String> {
        Thread.isMainThread
            ? MainActor.assumeIsolated { host.mirrorsInUse }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { host.mirrorsInUse } }
    }

    /// Not on the mirror queue: a list only reads, and must not wait behind a fetch.
    func listMirrors() async -> [RebasedMirrorRecord] {
        let list = mirrorList, directory = stateDirectory, inUse = mirrorsInUse
        let result = ResultBox<[RebasedMirrorRecord]>()
        await withCheckedContinuation { continuation in
            offMain({ result.set { list(directory, inUse) } }, { continuation.resume() })
        }
        return (try? result.value?.get()) ?? []
    }

    /// A refusal of the state lock comes back as the thrown error.
    func pruneMirrors(olderThanDays days: Int, dryRun: Bool) async throws -> RebasedMirrorCleanup.Report {
        let prune = mirrorPrune, directory = stateDirectory
        let result = ResultBox<RebasedMirrorCleanup.Report>()
        await withCheckedContinuation { continuation in
            onMirrorQueue({ [self] in
                let inUse = Self.inUseSnapshot(self)
                result.set { try prune(.init(stateDirectory: directory, inUse: inUse, maxAgeDays: days, dryRun: dryRun)) }
            }, { continuation.resume() })
        }
        return try (result.value ?? .failure(CancellationError())).get()
    }

    /// Only a real prune takes the lock: a second instance's mirrors are invisible here.
    nonisolated static func makeMirrorPrune(withLock lock: @escaping MirrorLock)
        -> @Sendable (RebasedMirrorCleanup.Request) throws -> RebasedMirrorCleanup.Report {
        { request in
            if request.dryRun { return RebasedMirrorCleanup.prune(request) }
            return try lock(request.stateDirectory.appendingPathComponent("rebased")) { RebasedMirrorCleanup.prune(request) }
        }
    }

    typealias RefreshLock = @Sendable (URL, () -> Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure>) throws
        -> Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure>

    /// A refresh holds the state lock as a prune does, so another agterm instance's prune cannot delete the clone
    /// mid-fetch. Held by another instance, the refresh fails.
    nonisolated static func makeMirrorRefresh(
        withLock lock: @escaping RefreshLock,
        run: @escaping @Sendable (RebasedMirror, URL) -> Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure> = {
            RebasedMirrorRefresh.run($0, stateDirectory: $1)
        }
    ) -> @Sendable (RebasedMirror, URL) -> Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure> {
        { mirror, directory in
            do {
                return try lock(directory.appendingPathComponent("rebased")) { run(mirror, directory) }
            } catch {
                return .failure(.init(message: error.localizedDescription))
            }
        }
    }

    nonisolated static func makeMirrorList() -> @Sendable (URL, Set<String>) -> [RebasedMirrorRecord] {
        { RebasedMirrorCleanup.scan(stateDirectory: $0, inUse: $1, measure: true) }
    }

    // MARK: - Helpers

    private func onCloseDirectory(for session: Session) -> String {
        let home = NSHomeDirectory()
        let path = session.localWorkingDirectory(reported: session.focusedCwd, homeDirectory: home)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : home
    }

    private func overlayID(for session: UUID) -> UUID? {
        store(session)?.session(withID: session)?.rebasedPlacement?.overlay.id
            ?? entries.filter { $0.value.session == session }.max { $0.value.order < $1.value.order }?.key
    }

    private func entry(for session: UUID) -> Entry? {
        entries.values.filter { $0.session == session }.max { $0.order < $1.order }
    }

    func overlay(_ entry: Entry) -> RebasedOverlay? {
        guard let overlay = store(entry.session)?.session(withID: entry.session)?.rebasedPlacement?.overlay,
              overlay.id == entry.id else { return nil }
        return overlay
    }

    private func overlayState(_ entry: Entry) -> RebasedOverlay.State? { overlay(entry)?.state }

    private func setState(_ state: RebasedOverlay.State, overlay id: UUID) {
        guard let entry = entries[id] else { return }
        store(entry.session)?.session(withID: entry.session)?.updateRebasedOverlay(id) { $0.state = state }
    }

    // The prune compares and hashes this same form, so `/private/tmp` against `/tmp` cannot split them.
    static func canonical(_ path: String) -> String {
        RebasedMirrorCleanup.projectPath(URL(fileURLWithPath: path))
    }

    /// The nearest directory at or above `cwd` holding `.git`, or `cwd` itself outside a repository. Read from
    /// the file system, not `git rev-parse`, whose process the main actor would wait on without bound.
    nonisolated static func projectDirectory(for cwd: String) -> String {
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory.path }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return cwd }
            directory = parent
        }
    }

    // An IDE frame is visible from the turn AWT orders it in; hide it there, before Core Animation commits,
    // until the frames keeper adopts it. Dialogs and popups are not miniaturizable and stay as they are.
    private func installBornObserver() {
        guard Self.bornObserver == nil else { return }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeSources.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, -1) { _, _ in
            MainActor.assumeIsolated { RebasedHost.shared.hideNewFrames() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Self.bornObserver = observer
    }

    private func installKeyObserver() {
        guard Self.keyObserver == nil else { return }
        Self.keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard Self.isIDEWindow(window) else { return }
                RebasedHost.shared.ideBecameKey(window)
            }
        }
    }

    // agterm's menu stays installed while the IDE is key, so without this a chord both menus bind (⌘F) would
    // fire agterm's item as well as reach the IDE.
    private func installKeyRouter() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: Self.monitor(self))
    }

    // `nil` is the consumed answer, so a gone host must not be folded into it with `??`.
    static func monitor(_ host: RebasedHost?) -> (NSEvent) -> NSEvent? {
        { [weak host] event in
            guard let host else { return event }
            return host.route(event)
        }
    }

    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }

    func route(_ event: NSEvent) -> NSEvent? {
        guard isIDEKeyWindow, let key = keyWindow() else { return event }
        let chord = event.keymapChord(produced: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)
        switch RebasedMenuPolicy(keymap: keymap()).route(chord, keyWindow: .ide) {
        case .agterm:
            return event
        case .toggle:
            if event.type == .keyDown { toggle(owner(of: key)) }
            return nil
        case .ide:
            key.sendEvent(event)
            return nil
        }
    }

    private func hideNewFrames() {
        for window in NSApp.windows where Self.isIDEWindow(window) && window.isVisible {
            guard seenWindows.insert(window.windowNumber).inserted,
                  window.styleMask.contains(.miniaturizable), window.parent == nil else { continue }
            window.alphaValue = 0
        }
    }
}

// Carries one off-main result back to the main actor; written once before the hop, read once after it.
final class ResultBox<Value>: @unchecked Sendable {
    private(set) var value: Result<Value, any Error>?
    func set(_ work: () throws -> Value) { value = Result(catching: work) }
}
