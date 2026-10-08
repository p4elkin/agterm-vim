import AppKit
import agtermCore

/// What the host does to IDE windows; `RebasedFrameKeeper` in the app, a recorder in tests.
@MainActor
protocol RebasedFrames: AnyObject {
    func adopt(_ frame: NSWindow, in host: NSWindow?)
    func attach(_ window: NSWindow, to host: NSWindow?)
    func detach(_ window: NSWindow)
    func orderOut(_ window: NSWindow)
    func refit(host: NSWindow)
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

    private struct Entry {
        let session: UUID
        let project: String
        let order: Int
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

    private(set) var jvm = JVM.notStarted
    private var entries: [UUID: Entry] = [:]
    private var frameNumbers: [String: Int] = [:]
    private(set) var visible: [String: UUID] = [:]
    // a slot is hidden until its view reports it on screen, so no path can show a frame over another session
    private var visibleSlots: Set<UUID> = []
    private var saving = false
    // keyed by overlay id: a released overlay's dialogs must never replay over the session's next project
    private var pendingDialogs: [UUID: [NSWindow]] = [:]
    // keyed by overlay id like the dialogs; sent once the frame is shown in its own session
    private var pendingDiffs: [UUID: RebasedDiff] = [:]
    private var slots: [ObjectIdentifier: NSRect] = [:]
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
                   keymap: @escaping () -> Keymap, toggle: @escaping (UUID?) -> Void) {
        self.appPath = appPath
        self.keymap = keymap
        self.toggle = toggle
        self.stateDirectory = stateDirectory
        store = { [weak library] in library?.store(forSession: $0) }
        hostWindow = { [weak library] session in
            library?.windowID(forSession: session).flatMap { WindowRegistry.shared.window(for: $0) }
        }
        (frames as? RebasedFrameKeeper)?.slotRect = { [weak self] window in
            self?.slots[ObjectIdentifier(window)] ?? window.convertToScreen(window.contentLayoutRect)
        }
        install()
    }

    func install() {
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
        case .running: return .init(jvm: "running", projects: projects)
        case .failed(let error): return .init(jvm: "failed", error: error, projects: projects)
        }
    }

    /// The overlay's frame is shown in this session, as opposed to waiting or shown in another session.
    func isShown(in session: UUID) -> Bool {
        visible.values.contains(session)
    }

    // MARK: - Opening

    /// Opens a Rebased overlay on `cwd`'s repository (the session's cwd without one): the shared path of
    /// `session.overlay.open --rebased` and `rebased_toggle`. Returns the refusal, nil when it opened.
    /// A `diff` for the project already open in the session goes to that overlay instead of a new one.
    func openOverlay(in store: AppStore, session id: UUID, cwd: String?, sizePercent: Int?, diff: RebasedDiff? = nil) -> String? {
        guard let session = store.session(withID: id) else { return RebasedOverlayOpenFailure.unknownSession.message }
        if session.remoteHost != nil { return Self.remoteRefusal }
        let project = Self.projectDirectory(for: cwd ?? session.focusedCwd)
        if let diff, let open = session.rebasedOverlay, Self.canonical(open.project) == Self.canonical(project) {
            session.rebasedOverlay?.diff = diff
            pendingDiffs[open.id] = diff
            sendDiff(session: id)
            return nil
        }
        if let failure = store.openRebasedOverlay(id, overlay: RebasedOverlay(project: project, diff: diff), sizePercent: sizePercent) {
            return failure.message
        }
        open(session: id)
        return nil
    }

    static let remoteRefusal = "Rebased overlays open on the Mac that holds the repository"

    /// Takes over a Rebased overlay the store has just opened in `session`.
    func open(session: UUID) {
        guard let overlay = store(session)?.session(withID: session)?.rebasedOverlay else { return }
        opens += 1
        let project = Self.canonical(overlay.project)
        entries[overlay.id] = Entry(session: session, project: project, order: opens)
        if let diff = overlay.diff { pendingDiffs[overlay.id] = diff }
        switch jvm {
        case .running:
            if frameNumbers[project] != nil { show(session: session) } else { _ = runtime.call("open", project) }
            armDeadline(overlay.id)
        case .starting:
            if prepared { armDeadline(overlay.id) }
        case .notStarted:
            start()
        case .failed(let error):
            if runtime.jvmCreated { setState(.failed(error), session: session) } else { start() }
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
            setState(.failed(Self.deadlineMessage), session: entry.session)
        }
    }

    private func fail(_ message: String) {
        jvm = .failed(message)
        for entry in entries.values where overlayState(entry) == .starting {
            setState(.failed(message), session: entry.session)
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
        case "failed":
            fail(payload)
        default:
            break
        }
    }

    // A frame that arrives after its overlays failed stays hidden for the next open instead of reviving them.
    private func frameOpened(project: String, number: Int) {
        frameNumbers[project] = number
        let waiting = entries.values.filter { $0.project == project && overlayState($0) == .starting }
        for entry in waiting { setState(.shown, session: entry.session) }
        let onScreen = waiting.filter { visibleSlots.contains($0.session) }
        guard let latest = onScreen.max(by: { $0.order < $1.order }) else {
            if visible[project] == nil { _ = runtime.call("hide", project) }
            return
        }
        show(session: latest.session)
    }

    private func frameClosed(project: String) {
        frameNumbers[project] = nil
        visible[project] = nil
        for entry in entries.values where entry.project == project {
            _ = store(entry.session)?.closeOverlay(entry.session)
        }
    }

    private func windowOpened(_ window: NSWindow, kind: String, owner: String?) {
        if kind == "welcome" { return frames.orderOut(window) }
        // the born observer hid it as a possible project frame; only the keeper reveals those
        window.alphaValue = 1
        if let owner, let session = visible[owner] {
            frames.attach(window, to: hostWindow(session))
        } else if kind == "dialog", let (id, waiting) = waiting(owner) {
            // IntelliJ can ask before any frame exists ("Trust project?"); it belongs to the slot being opened
            if visibleSlots.contains(waiting.session) {
                frames.attach(window, to: hostWindow(waiting.session))
            } else {
                frames.orderOut(window)
                pendingDialogs[id, default: []].append(window)
            }
        } else if owner == nil, let session = lastShown.flatMap({ isShown(in: $0) ? $0 : nil }) ?? visible.values.first {
            frames.attach(window, to: hostWindow(session))
        } else if kind == "dialog", let last = owner.map({ lastShownByProject[$0] }) ?? lastShown,
                  let current = entry(for: last), owner == nil || current.project == owner {
            reveal(session: last, dialog: window)
        } else {
            frames.orderOut(window)
        }
    }

    // The opening overlay a frameless dialog belongs to, the one on screen first, then the newest.
    private func waiting(_ project: String?) -> (UUID, Entry)? {
        entries.filter { (project == nil || $0.value.project == project) && overlayState($0.value) == .starting }
            .max { lhs, rhs in
                let left = visibleSlots.contains(lhs.value.session), right = visibleSlots.contains(rhs.value.session)
                return left == right ? lhs.value.order < rhs.value.order : !left
            }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Visibility

    /// A ready frame marks the overlay shown at once; the frame itself moves onto the slot only while the
    /// slot's view reports it on screen.
    func show(session: UUID) {
        guard let entry = entry(for: session), let number = frameNumbers[entry.project],
              let frame = window(number) else { return }
        if case .failed = overlayState(entry) { return }
        setState(.shown, session: session)
        guard visibleSlots.contains(session) else { return }
        visible[entry.project] = session
        lastShown = session
        lastShownByProject[entry.project] = session
        setState(.shown, session: session)
        _ = runtime.call("show", entry.project)
        frames.adopt(frame, in: hostWindow(session))
        sendDiff(session: session)
    }

    // The bridge shows the diff as a dialog of the project frame, so it waits until that frame is on screen
    // here; sent while hidden, the dialog would come up over another session or queue behind the slot.
    private func sendDiff(session: UUID) {
        guard let id = overlayID(for: session), let entry = entries[id], visible[entry.project] == session,
              let diff = pendingDiffs.removeValue(forKey: id) else { return }
        _ = runtime.call("diff", diff.bridgeArgument(project: entry.project))
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
        if visibleSlots.contains(session) {
            show(session: session)
            frames.attach(dialog, to: hostWindow(session))
        } else {
            frames.orderOut(dialog)
            if let id = overlayID(for: session) { pendingDialogs[id, default: []].append(dialog) }
        }
    }

    /// The session whose shown frame, or a window attached over it, is `window`.
    func owner(of window: NSWindow) -> UUID? {
        visible.first { project, session in
            frameNumbers[project].flatMap(self.window) === window
                || (window.parent != nil && window.parent === hostWindow(session))
        }?.value
    }

    /// The slot view's report: whether its session's slot is on screen and uncovered. Hiding the frame on
    /// a session switch, a closed or minimized window and an agterm palette over the slot all come here.
    func setSlotVisible(_ isVisible: Bool, session: UUID) {
        if isVisible {
            visibleSlots.insert(session)
            show(session: session)
            let queued = overlayID(for: session).flatMap { pendingDialogs.removeValue(forKey: $0) } ?? []
            for dialog in queued { surface(dialog, session: session) }
        } else {
            visibleSlots.remove(session)
            hide(session: session)
        }
    }

    func setSlot(_ rect: NSRect, in window: NSWindow) {
        guard slots[ObjectIdentifier(window)] != rect else { return }
        slots[ObjectIdentifier(window)] = rect
        frames.refit(host: window)
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
        guard visible[entry.project] == entry.session else { return }
        visible[entry.project] = nil
        _ = runtime.call("hide", entry.project)
        if let number = frameNumbers[entry.project], let frame = window(number) { frames.detach(frame) }
        handBack(entry)
    }

    // Another slot already on screen for the project would otherwise say "shown in another session" over
    // nothing until its own visibility changed.
    private func handBack(_ previous: Entry) {
        let next = entries.values.filter {
            $0.project == previous.project && $0.session != previous.session && visibleSlots.contains($0.session)
                && overlayState($0) == .shown
        }.max { $0.order < $1.order }
        if let next { show(session: next.session) }
    }

    // A queued dialog is still blocking the IDE (a modal "Trust project?" holds every project), so it is
    // never dropped: it comes up over the session now, rather than over whatever that session opens next.
    private func release(_ overlayID: UUID) {
        armed.remove(overlayID)
        pendingDiffs[overlayID] = nil
        let queued = pendingDialogs.removeValue(forKey: overlayID) ?? []
        guard let entry = entries.removeValue(forKey: overlayID) else { return }
        hide(entry)
        if lastShownByProject[entry.project] == entry.session { lastShownByProject[entry.project] = nil }
        for dialog in queued { surface(dialog, session: entry.session) }
    }

    private func surface(_ dialog: NSWindow, session: UUID) {
        frames.attach(dialog, to: hostWindow(session))
        dialog.orderFront(nil)
    }

    // MARK: - Helpers

    private func overlayID(for session: UUID) -> UUID? {
        entries.filter { $0.value.session == session }.max { $0.value.order < $1.value.order }?.key
    }

    private func entry(for session: UUID) -> Entry? {
        entries.values.filter { $0.session == session }.max { $0.order < $1.order }
    }

    private func overlayState(_ entry: Entry) -> RebasedOverlay.State? {
        store(entry.session)?.session(withID: entry.session)?.rebasedOverlay?.state
    }

    private func setState(_ state: RebasedOverlay.State, session: UUID) {
        store(session)?.session(withID: session)?.rebasedOverlay?.state = state
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
private final class ResultBox<Value>: @unchecked Sendable {
    private(set) var value: Result<Value, any Error>?
    func set(_ work: () throws -> Value) { value = Result(catching: work) }
}
