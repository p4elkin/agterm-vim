import agtermCore
import Foundation
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "zmx")

/// The zmx effects the app performs, as closures so every decision above them stays host-free in
/// `agtermCore` (`ZmxWrap`, `ZmxListParser`, `ZmxSocketBudget`) and only the subprocess calls live here.
/// `.noop` is what a test injects.
struct ZmxClient: Sendable {
    /// The installed binary, nil when zmx is not on the widened PATH.
    var locate: @Sendable () -> String?
    /// `zmx list`, parsed. nil means the listing could not be READ; an empty listing parses to `[]`, and the
    /// reaper turns on that difference.
    var list: @Sendable () -> [ZmxListParser.Entry]?
    /// `zmx set <key> agterm_name=<name>`. zmx has no rename, so the label is what carries a renamed row.
    var setLabel: @Sendable (_ key: String, _ name: String) -> Void
    /// `zmx kill <key>`, ending the session and every client attached to it.
    var kill: @Sendable (_ key: String) -> Void
}

extension ZmxClient {
    static let noop = ZmxClient(locate: { nil }, list: { nil }, setLabel: { _, _ in }, kill: { _ in })

    static let live = makeLive(listTimeout: defaultTimeout)

    /// The client a `tree` read uses. Identical but for the listing's budget: `agtermctl tree` runs on the
    /// main actor and agent hooks call it constantly, so an unresponsive daemon may stall the UI for a
    /// fraction of a second, never for the two seconds a background reap can afford. A listing that does not
    /// arrive costs nothing — the pane reports its own `zmx attach` argv, today's answer.
    static let mainActorBounded = makeLive(listTimeout: mainActorListTimeout)

    static func makeLive(listTimeout: TimeInterval) -> ZmxClient {
        ZmxClient(
            locate: { locateBinary() },
            list: {
                guard let zmx = locateBinary(),
                      let output = capture(zmx, ["list"], timeout: listTimeout) else { return nil }
                return ZmxListParser.parse(output)
            },
            setLabel: { key, name in
                guard let zmx = locateBinary() else { return }
                // a pane is labelled the moment it is wrapped, which is BEFORE its own `zmx attach` has
                // created the session, and `zmx set` on a session that is not there yet exits non-zero. Retry
                // briefly rather than leave every never-renamed row showing a bare uuid in `zmx list`.
                for attempt in 0..<labelAttempts {
                    if attempt > 0 { Thread.sleep(forTimeInterval: labelRetryInterval) }
                    if capture(zmx, ["set", key, "agterm_name=\(name)"]) != nil { return }
                }
            },
            kill: { key in
                guard let zmx = locateBinary() else { return }
                _ = capture(zmx, ["kill", key])
            }
        )
    }

    /// Where `zmx` is, scanned over the same widened PATH a custom command gets: the app's own PATH is
    /// launchd's and carries no `/opt/homebrew/bin`. A stat scan rather than `which`, because a surface
    /// factory asks this on the main actor while building a pane and must not spawn a process to answer.
    static func locateBinary(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let manager = FileManager.default
        for dir in CommandPath.widened(env["PATH"], bundledCLIDirectory: nil).split(separator: ":") {
            let candidate = "\(dir)/zmx"
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// How long a zmx call may take before it is abandoned. Every caller has a usable answer for "nothing
    /// came back": an unwrapped pane, an unknown client count, a label left as it was.
    static let defaultTimeout: TimeInterval = 2

    /// The budget for a call made from the main actor. A measured `zmx list` with 41 live sessions takes
    /// about 11 ms, so this is two orders of magnitude of slack and still short of a visible stall.
    static let mainActorListTimeout: TimeInterval = 0.4

    /// How long an abandoned child gets to honour SIGTERM before SIGKILL frees the drain thread.
    static let terminateGrace: TimeInterval = 1

    /// How many times a label is attempted, and how long apart. The first attempt races the pane's own
    /// `zmx attach`, so the run has to cover a session that takes a moment to exist; every attempt after the
    /// successful one is skipped, so a rename still costs exactly one call.
    static let labelAttempts = 5
    static let labelRetryInterval: TimeInterval = 0.4

    /// Run a zmx subcommand and return its stdout, or nil when it could not be spawned, overran the timeout,
    /// or exited non-zero. stdout is drained on another queue: a full pipe buffer blocks the child, and the
    /// thread that would drain it is the one waiting here.
    static func capture(_ executable: String, _ arguments: [String],
                        timeout: TimeInterval = defaultTimeout) -> String? {
        let subcommand = arguments.first ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("zmx \(subcommand, privacy: .public) failed to spawn: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // FileHandle is not Sendable; the handle is used by this closure alone, and only until it hits EOF.
        nonisolated(unsafe) let reader = pipe.fileHandleForReading
        let collected = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = reader.readDataToEndOfFile()
            collected.withLock { $0 = data }
            drained.signal()
        }
        guard drained.wait(timeout: .now() + timeout) == .success else {
            // do NOT wait for the terminated child here: this thread is a pane being built, and a zmx that
            // already overran its budget must not hold it any longer. Foundation reaps it.
            process.terminate()
            // a child that ignores SIGTERM keeps the pipe's write end open, and the drain closure above stays
            // blocked on it forever — one leaked thread and one leaked Pipe per timeout. Follow up out of
            // band so the read hits EOF; the Process object holds the pid, so it cannot have been recycled.
            nonisolated(unsafe) let child = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminateGrace) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
            logger.error("zmx \(subcommand, privacy: .public) timed out")
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.notice("zmx \(subcommand, privacy: .public) exited \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return String(decoding: collected.withLock { $0 }, as: UTF8.self)
    }
}

/// Assembles `ZmxWrap.Inputs` for the two surface factories from the app's environment and the located
/// binary, and reports the outcome to the log. A struct rather than static functions so a test can drive the
/// same seam with an environment and a client of its own.
struct ZmxWrapping: Sendable {
    let env: [String: String]
    let client: ZmxClient

    /// What the surface factories use.
    static let live = ZmxWrapping(env: ProcessInfo.processInfo.environment, client: .live)

    /// The macOS default login shell, used when `$SHELL` is unset. A full path, never a basename: it is
    /// `exec`ed inside the keep-shell-open wrapper's `-lc` script.
    static let fallbackShell = "/bin/zsh"

    /// The variable zmx exports into a session's shell, and the one an agterm launched from inside a wrapped
    /// pane inherits. `ZMX_DIR` is deliberately NOT touched: the budget probe and every spawned `zmx` call
    /// need whatever directory the user pinned.
    static let inheritedSessionVariable = "ZMX_SESSION"

    /// What a wrapped pane runs and which zmx session it thereby owns. The caller must record `key` on the
    /// session: it is the ONLY place the ownership is decided, and re-deriving it later gets a promoted split
    /// survivor wrong.
    struct Wrapped {
        let command: String
        let key: String
    }

    /// The command this pane should run instead of what it would have run, or nil to leave it exactly as it
    /// is. Every nil is a normal outcome — no binary, an over-budget socket path, an isolated state
    /// directory, a plain `--command` row — so the wrapping can never break a pane.
    /// `keys` is `Session.zmxKeys(for:)`, taken whole rather than as two arguments so the pane's own key and
    /// its sibling's cannot be handed over the wrong way round.
    func command(sessionID: UUID, role: ZmxSessionKey.Role, keys: (own: String?, sibling: String?),
                 pinnedCommand: String?, keepShellOpen: Bool) -> Wrapped? {
        let probe = ZmxSocketBudget.probe(env: env, keyByteCount: ZmxSessionKey.maxByteCount)
        let inputs = ZmxWrap.Inputs(sessionID: sessionID, role: role, existingKey: keys.own,
                                    siblingKey: keys.sibling, pinnedCommand: pinnedCommand,
                                    keepShellOpen: keepShellOpen, shell: shell,
                                    zmxPath: client.locate(), budgetReason: probe,
                                    isolatedStateDir: env["AGTERM_STATE_DIR"] != nil,
                                    skipRequested: !(env["AGTERM_ZMX_SKIP"] ?? "").isEmpty)
        let pane = "\(sessionID.uuidString)-\(role.rawValue)"
        switch ZmxWrap.decide(inputs) {
        case .wrap(let command, let key):
            logger.info("pane \(pane, privacy: .public) runs zmx session \(key, privacy: .public)")
            return Wrapped(command: command, key: key)
        case .unwrapped(let reason):
            logger.notice("pane \(pane, privacy: .public) not wrapped: \(reason, privacy: .public)")
            return nil
        }
    }

    /// The close/rename effects, as the host-free sink `AppStore` calls. Both are handed to a background
    /// queue: they run from a row close and a rename, and a `zmx` that hits its timeout would otherwise hold
    /// the main actor for two seconds. Under an isolated state directory nothing was wrapped, so nothing may
    /// be ended or relabelled either — that instance must never reach the deployed app's daemons.
    @MainActor var sessionSink: ZmxSessionSink {
        let client = env["AGTERM_STATE_DIR"] == nil ? client : .noop
        return ZmxSessionSink(
            end: { key in
                logger.info("ending zmx session \(key, privacy: .public)")
                DispatchQueue.global(qos: .utility).async { client.kill(key) }
            },
            label: { key, name in
                DispatchQueue.global(qos: .utility).async { client.setLabel(key, name) }
            }
        )
    }

    /// End the detached daemons nothing claims any more: a row whose app was force-quit before its close
    /// could end them, or one the old `~/.zprofile` hook left behind. Runs off the main actor because it
    /// spawns `zmx list` and one `zmx kill` per orphan.
    ///
    /// ⚠️ Skipped entirely under `AGTERM_STATE_DIR`. An isolated instance wraps nothing, so every daemon it
    /// can see belongs to the deployed app and killing one would end a live agent session.
    func reapOrphanedSessions(directory: URL = PersistenceStore.defaultDirectory) {
        guard env["AGTERM_STATE_DIR"] == nil else { return }
        let client = client
        DispatchQueue.global(qos: .utility).async {
            // the listing is taken BEFORE the claimed set, never after: a row created while this runs is
            // absent from the listing and so cannot be reaped, while the other order would see its daemon
            // without seeing the snapshot that claims it.
            guard let listing = client.list() else { return }
            guard let claimed = ZmxReaper.persistedClaim(directory: directory) else {
                // one unreadable window file turns the whole reap off, which is the safe answer but an
                // invisible one: without this the daemons pile up with nothing to explain why.
                logger.notice("skipping the zmx reap: the persisted window claim could not be read")
                return
            }
            for key in ZmxReaper.orphans(in: listing, claimed: claimed) {
                logger.info("reaping orphaned zmx session \(key, privacy: .public)")
                client.kill(key)
            }
        }
    }

    private var shell: String {
        env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackShell
    }

    /// Drops an inherited `ZMX_SESSION`, so a pane spawned by an agterm that was itself launched from inside
    /// a wrapped pane does not report its parent's session identity. libghostty spawns from the app's own
    /// environment, so this has to run before any surface exists.
    static func scrubInheritedSession() { unsetenv(inheritedSessionVariable) }
}
