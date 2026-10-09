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
    var isIDEKeyWindowOverride: Bool?
    var isFocusedPane: (UUID, OverlayPane) -> Bool = { _, _ in false }
    var mirrorRefresh: @Sendable (RebasedMirror, URL) -> Result<RebasedMirrorRefresh.Copy, RebasedMirrorRefresh.Failure> = {
        RebasedMirrorRefresh.run($0, stateDirectory: $1)
    }
    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "RebasedHost")

    private(set) var jvm = JVM.notStarted
    var entries: [UUID: Entry] = [:]
    private var frameNumbers: [String: Int] = [:]
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
    private var armed: Set<UUID> = []
    private var prepared = false
    private var bound = false
    private var deadlinePassed = false
    private var opens = 0
    private var bornObserver: CFRunLoopObserver?
    private var keyMonitor: Any?
    private var seenWindows: Set<Int> = []

    func configure(library: WindowLibrary, appPath: @escaping () -> String, stateDirectory: URL,
                   keymap: @escaping () -> Keymap, toggle: @escaping (UUID?) -> Void,
                   environment: @escaping (Session, AppStore) -> [String: String]) {
        self.appPath = appPath
        self.keymap = keymap
        self.toggle = toggle
        self.environment = environment
        self.stateDirectory = stateDirectory
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
        let captured = onClose.map { RebasedOnClose(command: $0, cwd: cwd ?? session.focusedCwd, environment: environment(session, store)) }
        if session.remoteHost != nil {
            return openRemote(in: store, session: session, path: cwd ?? session.focusedCwd, sizePercent: sizePercent, view: view, pane: pane)
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
        open(session: id)
        return .success(.init(overlay: overlay.id, request: overlay.view?.id))
    }

    // MARK: - Remote rows

    func openRemote(in store: AppStore, session: Session, path: String, sizePercent: Int?, view: RebasedView?,
                    pane: OverlayPane?) -> Result<RebasedOpened, RebasedOpenRefusal> {
        let host = session.remoteHost ?? ""
        guard let mirror = RebasedMirror(host: host, path: path) else {
            return .failure(.init(message: "Rebased cannot mirror \(host):\(path)"))
        }
        if fetching.contains(session.id) { return .failure(.init(message: "Rebased is still fetching from \(host)")) }
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
        offMain({ result.set { try refresh(mirror, directory).get() } }, { [weak self] in
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
        guard let model = store(session)?.session(withID: session), var overlay = model.rebasedPlacement?.overlay else { return }
        if overlay.view == nil, let diff = overlay.diff {
            overlay.view = RebasedViewRequest(view: .diff(diff, workingTree: false))
            model.updateRebasedOverlay(overlay.id) { $0.view = overlay.view }
        }
        opens += 1
        let project = Self.canonical(overlay.project)
        entries[overlay.id] = Entry(id: overlay.id, session: session, project: project, order: opens, onClose: overlay.onClose)
        if store(session)?.session(withID: session)?.rebasedPlacement?.pane != nil { needsInitialFocus.insert(overlay.id) }
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
        let runtime = runtime, path = appPath(), directory = stateDirectory
        let result = ResultBox<RebasedLaunch>()
        offMain({ result.set { try runtime.prepare(appPath: path, stateDirectory: directory) } }, { [weak self] in
            guard let self else { return }
            switch result.value {
            case .success(let launch):
                prepared = true
                for (id, entry) in entries where overlayState(entry) == .starting { armDeadline(id) }
                self.launch(launch)
            case .failure(let error):
                fail(error.localizedDescription)
            case nil:
                break
            }
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
        guard armed.insert(id).inserted else { return }
        after(Self.readyDeadline) { [weak self] in
            guard let self else { return }
            armed.remove(id)
            if jvm == .starting { deadlinePassed = true }
            guard let entry = entries[id], overlayState(entry) == .starting else { return }
            setState(.failed(Self.deadlineMessage), overlay: entry.id)
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

    func show(overlay id: UUID) {
        guard let entry = entries[id], let number = frameNumbers[entry.project], let frame = window(number) else { return }
        if case .failed = overlayState(entry) { return }
        guard overlay(entry)?.hidden != true, overlayState(entry) != .fetching else { return }
        setState(.shown, overlay: id)
        guard visibleSlots.contains(id) else { return }
        visible[entry.project] = id
        lastShown = id
        lastShownByProject[entry.project] = id
        _ = runtime.call("show", entry.project)
        frames.adopt(frame, in: hostWindow(entry.session))
        sendView(overlay: id)
        if needsInitialFocus.remove(id) != nil,
           let pane = store(entry.session)?.session(withID: entry.session)?.rebasedPlacement?.pane,
           isFocusedPane(entry.session, pane) { focus(overlay: id) }
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
        if isVisible { visibilityReports[id, default: []].insert(reporter) }
        else { visibilityReports[id]?.remove(reporter) }
        let nowVisible = visibilityReports[id]?.isEmpty == false
        if nowVisible { visibleSlots.insert(id) }
        else {
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

    // A queued dialog is still blocking the IDE (a modal "Trust project?" holds every project), so it is
    // never dropped: it comes up over the session now, rather than over whatever that session opens next.
    func removeEntry(_ overlayID: UUID) -> Entry? {
        guard let entry = entries.removeValue(forKey: overlayID) else { return nil }
        armed.remove(overlayID)
        visibleSlots.remove(overlayID)
        visibilityReports[overlayID] = nil
        needsInitialFocus.remove(overlayID)
        slots[overlayID] = nil
        let queued = pendingDialogs.removeValue(forKey: overlayID) ?? []
        hide(entry)
        if lastShownByProject[entry.project] == entry.id { lastShownByProject[entry.project] = nil }
        for dialog in queued { surface(dialog, session: entry.session) }
        return entry
    }

    private func surface(_ dialog: NSWindow, session: UUID) {
        frames.attach(dialog, to: hostWindow(session))
        dialog.orderFront(nil)
    }

    // MARK: - Helpers

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

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
        guard bornObserver == nil else { return }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeSources.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, -1) { _, _ in
            MainActor.assumeIsolated { RebasedHost.shared.hideNewFrames() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        bornObserver = observer
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
