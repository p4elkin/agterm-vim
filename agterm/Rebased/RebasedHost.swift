import AppKit
import agtermCore

/// What the host does to IDE windows. Task 10's frame keeper replaces the plain child-window version.
@MainActor
protocol RebasedFrames: AnyObject {
    func adopt(_ frame: NSWindow, in host: NSWindow?)
    func attach(_ window: NSWindow, to host: NSWindow?)
    func detach(_ window: NSWindow)
    func orderOut(_ window: NSWindow)
}

@MainActor
final class ChildWindowFrames: RebasedFrames {
    func adopt(_ frame: NSWindow, in host: NSWindow?) {
        attach(frame, to: host)
        frame.alphaValue = 1
    }

    func attach(_ window: NSWindow, to host: NSWindow?) {
        guard let host, window.parent !== host else { return }
        window.parent?.removeChildWindow(window)
        host.addChildWindow(window, ordered: .above)
    }

    func detach(_ window: NSWindow) { window.parent?.removeChildWindow(window) }
    func orderOut(_ window: NSWindow) { window.orderOut(nil) }
}

/// Owns the embedded Rebased JVM and maps its project frames onto session overlays; the single owner, like
/// `HtmlOverlayRegistry`. The JVM, once created, lives as long as the process: HotSpot cannot start twice.
@MainActor
final class RebasedHost {
    static let shared = RebasedHost()
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
    var frames: any RebasedFrames = ChildWindowFrames()
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
    var offMain: (@escaping @Sendable () -> (any Error)?, @escaping @MainActor @Sendable ((any Error)?) -> Void) -> Void = { work, done in
        Task.detached(priority: .userInitiated) {
            let error = work()
            await done(error)
        }
    }
    var isIDEKeyWindowOverride: Bool?

    private(set) var jvm = JVM.notStarted
    private var entries: [UUID: Entry] = [:]
    private var frameNumbers: [String: Int] = [:]
    private(set) var visible: [String: UUID] = [:]
    private var lastShown: UUID?
    private var bound = false
    private var deadlinePassed = false
    private var opens = 0
    private var bornObserver: CFRunLoopObserver?
    private var seenWindows: Set<Int> = []

    func configure(library: WindowLibrary, appPath: @escaping () -> String, stateDirectory: URL) {
        self.appPath = appPath
        self.stateDirectory = stateDirectory
        store = { [weak library] in library?.store(forSession: $0) }
        hostWindow = { [weak library] session in
            library?.windowID(forSession: session).flatMap { WindowRegistry.shared.window(for: $0) }
        }
        install()
    }

    func install() {
        RebasedOverlayReleases.shared.onRelease = { [weak self] in self?.release($0) }
    }

    var isIDEKeyWindow: Bool {
        isIDEKeyWindowOverride ?? NSApp.keyWindow.map(Self.isIDEWindow) ?? false
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

    /// Takes over a Rebased overlay the store has just opened in `session`.
    func open(session: UUID) {
        guard let overlay = store(session)?.session(withID: session)?.rebasedOverlay else { return }
        opens += 1
        let project = Self.canonical(overlay.project)
        entries[overlay.id] = Entry(session: session, project: project, order: opens)
        switch jvm {
        case .running:
            if frameNumbers[project] != nil { show(session: session) } else { _ = runtime.call("open", project) }
            armDeadline()
        case .starting:
            if deadlinePassed { armDeadline() }
        case .notStarted:
            start()
        case .failed(let error):
            if runtime.jvmCreated { setState(.failed(error), session: session) } else { start() }
        }
    }

    private func start() {
        jvm = .starting
        bound = false
        deadlinePassed = false
        installBornObserver()
        let runtime = runtime, path = appPath(), directory = stateDirectory
        offMain({
            do { try runtime.start(appPath: path, stateDirectory: directory) } catch { return error }
            return nil
        }, { [weak self] error in
            guard let self else { return }
            if let error { fail(error.localizedDescription) } else { armDeadline(); bind() }
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

    private func armDeadline() {
        let waiting = Set(entries.keys)
        after(Self.readyDeadline) { [weak self] in
            guard let self else { return }
            if jvm == .starting { deadlinePassed = true }
            for id in waiting {
                guard let entry = entries[id], overlayState(entry) == .starting else { continue }
                setState(.failed(Self.deadlineMessage), session: entry.session)
            }
        }
    }

    private func fail(_ message: String) {
        jvm = .failed(message)
        for entry in entries.values where overlayState(entry) == .starting {
            setState(.failed(message), session: entry.session)
        }
    }

    // MARK: - Events

    func handle(event kind: String, payload: String) {
        let fields = payload.components(separatedBy: "\t")
        switch kind {
        case "ready":
            jvm = .running
            deadlinePassed = false
            let waiting = entries.values.filter { overlayState($0) == .starting }
            for project in Set(waiting.map(\.project)) where frameNumbers[project] == nil {
                _ = runtime.call("open", project)
            }
        case "frameOpened":
            guard fields.count == 2, let number = Int(fields[1]) else { return }
            frameOpened(project: Self.canonical(fields[0]), number: number)
        case "frameClosed":
            frameClosed(project: Self.canonical(payload))
        case "windowOpened":
            guard fields.count == 2, let number = Int(fields[0]), let window = window(number) else { return }
            windowOpened(window, kind: fields[1])
        case "failed":
            fail(payload)
        default:
            break
        }
    }

    private func frameOpened(project: String, number: Int) {
        frameNumbers[project] = number
        let waiting = entries.values.filter { $0.project == project }
        for entry in waiting { setState(.shown, session: entry.session) }
        if let latest = waiting.max(by: { $0.order < $1.order }) { show(session: latest.session) }
    }

    private func frameClosed(project: String) {
        frameNumbers[project] = nil
        visible[project] = nil
        for entry in entries.values where entry.project == project {
            _ = store(entry.session)?.closeOverlay(entry.session)
        }
    }

    private func windowOpened(_ window: NSWindow, kind: String) {
        if kind == "welcome" {
            frames.orderOut(window)
        } else if let session = visible.values.first {
            frames.attach(window, to: hostWindow(session))
        } else if kind == "dialog", let last = lastShown, entry(for: last) != nil {
            show(session: last)
            frames.attach(window, to: hostWindow(last))
        } else {
            frames.orderOut(window)
        }
    }

    // MARK: - Visibility

    func show(session: UUID) {
        guard let entry = entry(for: session), let number = frameNumbers[entry.project],
              let frame = window(number) else { return }
        visible[entry.project] = session
        lastShown = session
        setState(.shown, session: session)
        _ = runtime.call("show", entry.project)
        frames.adopt(frame, in: hostWindow(session))
    }

    func hide(session: UUID) {
        guard let entry = entry(for: session) else { return }
        hide(entry)
    }

    private func hide(_ entry: Entry) {
        guard visible[entry.project] == entry.session else { return }
        visible[entry.project] = nil
        _ = runtime.call("hide", entry.project)
        if let number = frameNumbers[entry.project], let frame = window(number) { frames.detach(frame) }
    }

    private func release(_ overlayID: UUID) {
        guard let entry = entries.removeValue(forKey: overlayID) else { return }
        hide(entry)
    }

    // MARK: - Helpers

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

    /// The repository holding `cwd`, or `cwd` itself outside a repository.
    nonisolated static func projectDirectory(for cwd: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "rev-parse", "--show-toplevel"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return cwd }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let top = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !top.isEmpty ? top : cwd
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

    private func hideNewFrames() {
        for window in NSApp.windows where Self.isIDEWindow(window) && window.isVisible {
            guard seenWindows.insert(window.windowNumber).inserted,
                  window.styleMask.contains(.miniaturizable), window.parent == nil else { continue }
            window.alphaValue = 0
        }
    }
}
