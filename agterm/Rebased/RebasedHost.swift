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
    private var entries: [UUID: Entry] = [:]
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
    private var saving = false
    // keyed by overlay id: a released overlay's dialogs must never replay over the session's next project
    private var pendingDialogs: [UUID: [NSWindow]] = [:]
    // keyed by overlay id like the dialogs; sent once the frame is shown in its own session
    private var pendingDiffs: [UUID: RebasedDiff] = [:]
    // sessions whose mirror is being refreshed; a second open would race the same git directory
    private var fetching: Set<UUID> = []
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

    func configure(library: WindowLibrary, settings: @escaping () -> AppSettings, stateDirectory: URL,
                   keymap: @escaping () -> Keymap, toggle: @escaping (UUID?) -> Void) {
        appPath = { settings().effectiveRebasedAppPath }
        self.keymap = keymap
        self.toggle = toggle
        self.stateDirectory = stateDirectory
        mirrorMaxAgeDays = { settings().effectiveRebasedMirrorMaxAgeDays }
        mirrorPrune = Self.makeMirrorPrune(withLock: RebasedStateLock.withLockIfFree)
        mirrorList = Self.makeMirrorList()
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
        if session.remoteHost != nil {
            return openRemote(in: store, session: session, path: cwd ?? session.focusedCwd, sizePercent: sizePercent, diff: diff)
        }
        let project = Self.projectDirectory(for: cwd ?? session.focusedCwd)
        if let diff, let open = session.rebasedOverlay, Self.canonical(open.project) == Self.canonical(project) {
            deliver(diff, to: session)
            return nil
        }
        let overlay = RebasedOverlay(project: project, diff: diff)
        if let failure = store.openRebasedOverlay(id, overlay: overlay, sizePercent: sizePercent) {
            return failure.message
        }
        if Self.isMirror(project, stateDirectory: stateDirectory) {
            openAfterMirrorJobs(session: id, overlay: overlay.id, project: project)
        } else {
            open(session: id)
        }
        return nil
    }

    /// A local overlay on a mirror's clone waits for any prune queued ahead of it, and a prune queued after it keeps
    /// the clone through `pendingMirrorOpens`; a clone that prune removed fails the overlay rather than opening nothing.
    private func openAfterMirrorJobs(session id: UUID, overlay overlayID: UUID, project: String) {
        pendingMirrorOpens[overlayID] = Self.canonical(project)
        onMirrorQueue({}, { [weak self] in
            guard let self, pendingMirrorOpens.removeValue(forKey: overlayID) != nil,
                  store(id)?.session(withID: id)?.rebasedOverlay?.id == overlayID else { return }
            if FileManager.default.fileExists(atPath: project) {
                open(session: id)
            } else {
                setState(.failed("Rebased mirror \(project) was removed by a prune"), session: id)
            }
        })
    }

    private static func isMirror(_ project: String, stateDirectory: URL) -> Bool {
        let mirrors = canonical(stateDirectory.appendingPathComponent("rebased/mirrors", isDirectory: true).path)
        return canonical(project).hasPrefix(mirrors + "/")
    }

    private func deliver(_ diff: RebasedDiff, to session: Session) {
        guard let open = session.rebasedOverlay else { return }
        session.rebasedOverlay?.diff = diff
        pendingDiffs[open.id] = diff
        sendDiff(session: session.id)
    }

    // MARK: - Remote rows

    /// A remote row opens a `RebasedMirror` of its host's repository, refreshed on every open so a range names the
    /// host's newest commits. The slot shows `fetching` until the first refresh lands.
    private func openRemote(in store: AppStore, session: Session, path: String, sizePercent: Int?, diff: RebasedDiff?) -> String? {
        let host = session.remoteHost ?? ""
        guard let mirror = RebasedMirror(host: host, path: path) else { return "Rebased cannot mirror \(host):\(path)" }
        if fetching.contains(session.id) { return "Rebased is still fetching from \(host)" }
        let overlayID: UUID
        if let open = session.rebasedOverlay {
            guard let source = open.source, RebasedMirror.covers(source: source, host: host, path: path) else {
                return RebasedOverlayOpenFailure.alreadyOpen.message
            }
            overlayID = open.id
        } else {
            let placeholder = RebasedOverlay(project: path, state: .fetching, diff: diff, source: mirror.source(top: path))
            if let failure = store.openRebasedOverlay(session.id, overlay: placeholder, sizePercent: sizePercent) {
                return failure.message
            }
            overlayID = placeholder.id
        }
        fetching.insert(session.id)
        let refresh = mirrorRefresh, directory = stateDirectory, sessionID = session.id
        let result = ResultBox<RebasedMirrorRefresh.Copy>()
        onMirrorQueue({ result.set { try refresh(mirror, directory).get() } }, { [weak self] in
            self?.mirrored(result.value, session: sessionID, overlay: overlayID, diff: diff)
        })
        return nil
    }

    // A failed refresh under an open IDE sends no range: the mirror would answer with the host's older commits.
    private func mirrored(_ result: Result<RebasedMirrorRefresh.Copy, any Error>?, session sessionID: UUID, overlay overlayID: UUID,
                          diff: RebasedDiff?) {
        fetching.remove(sessionID)
        guard let session = store(sessionID)?.session(withID: sessionID), let current = session.rebasedOverlay,
              current.id == overlayID else { return }
        switch (result, current.state == .fetching) {
        case (.success(let copy)?, true):
            session.rebasedOverlay = RebasedOverlay(project: copy.directory, diff: current.diff, source: copy.source, id: overlayID)
            open(session: sessionID)
        case (.success?, false):
            if let diff { deliver(diff, to: session) }
        case (.failure(let error)?, let placeholder):
            let message = (error as? RebasedMirrorRefresh.Failure)?.message ?? error.localizedDescription
            if placeholder { setState(.failed(message), session: sessionID) }
            Self.logger.error("\(message, privacy: .public)")
        case (nil, _):
            break
        }
    }

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
        openedThisRun.insert(project)
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
        touchMirror(project: entry.project, session: session)
    }

    // An overlay only shown and hidden for weeks would otherwise keep a marker as old as its last refresh, and the
    // first prune after it closes would delete a mirror in daily use. Cheapest checks first.
    private func touchMirror(project: String, session: UUID) {
        guard let source = store(session)?.session(withID: session)?.rebasedOverlay?.source else { return }
        let now = clock()
        if let last = lastTouched[project], now.timeIntervalSince(last) < Self.touchInterval { return }
        guard let hash = RebasedMirrorCleanup.hashDirectory(ofClone: URL(fileURLWithPath: project), stateDirectory: stateDirectory)
        else { return }
        lastTouched[project] = now
        onMirrorQueue({ RebasedMirrorMarker.touch(hashDirectory: hash, source: source, now: now) }, {})
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
        pendingMirrorOpens[overlayID] = nil
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
