import agtermCore
import Foundation

/// Closes panes whose zmx daemon has gone, as a pane's exit does in the app. A pane closes only once its daemon
/// was listed and then is not: a daemon that never appeared may still be coming (a park replay restores after the
/// server starts, and `zmx run` returns before the listing shows it), so an unlisted pane waits out a grace from
/// the server's start, or from when the watcher first saw a pane created later, before it counts as gone.
@MainActor
public final class DaemonWatcher {
    public static let startupGrace: TimeInterval = 600
    static let interval: Duration = .seconds(5)

    private let headless: Headless
    private let now: () -> Date
    private let startedAt: Date
    private let restored: Set<UUID>
    private var listed: Set<UUID> = []
    private var firstSeen: [UUID: Date] = [:]
    private var task: Task<Void, Never>?

    public init(headless: Headless, now: @escaping () -> Date = Date.init) {
        self.headless = headless
        self.now = now
        startedAt = now()
        restored = Set(Self.sessions(in: headless).flatMap { Self.panes(of: $0.session) })
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// One listing; a failed or unreadable one changes nothing.
    func poll() async {
        guard case .ok(let output) = await headless.runner.runInBackground(["list"], timeout: Headless.commandTimeout),
              let records = try? ZmxListParser.parse(output) else { return }
        let names = Set(records.map(\.name))
        headless.daemonLeaders = Dictionary(records.compactMap { record in record.leaderPID.map { (record.name, $0) } },
                                            uniquingKeysWith: { first, _ in first })
        defer { prune() }
        for (store, session) in Self.sessions(in: headless) {
            // the split first, so a session losing both panes in one listing closes rather than promotes a dead split
            if session.hasSplit, let split = session.splitPaneIdentity, gone(split, names: names) {
                headless.paneExited(.right, of: session, in: store)
            }
            if gone(session.paneIdentity, names: names) {
                headless.paneExited(.left, of: session, in: store)
            }
        }
    }

    var tracked: Set<UUID> { listed.union(firstSeen.keys) }

    private func prune() {
        let live = Set(Self.sessions(in: headless).flatMap { Self.panes(of: $0.session) })
        listed.formIntersection(live)
        firstSeen = firstSeen.filter { live.contains($0.key) }
    }

    private func gone(_ pane: UUID, names: Set<String>) -> Bool {
        if names.contains(ZmxSupport.daemonName(for: pane)) {
            listed.insert(pane)
            return false
        }
        if listed.contains(pane) { return true }
        let since = restored.contains(pane) ? startedAt : firstSeen[pane, default: now()]
        firstSeen[pane] = since
        return now() >= since + Self.startupGrace
    }

    private static func panes(of session: Session) -> [UUID] {
        [session.paneIdentity] + [session.hasSplit ? session.splitPaneIdentity : nil].compactMap { $0 }
    }

    private static func sessions(in headless: Headless) -> [(store: AppStore, session: Session)] {
        headless.library.windows.compactMap { headless.library.store(for: $0.id) }.flatMap { store in
            store.workspaces.flatMap(\.sessions).map { (store, $0) }
        }
    }
}
