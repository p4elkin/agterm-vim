import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ZmxResult: Sendable, Equatable {
    case ok(String)
    case failed(Int32, String)
    case timedOut
    case launchFailed(String)
}

public protocol ZmxRunning: Sendable {
    func run(_ arguments: [String], environment: [String: String], workingDirectory: String?,
             timeout: TimeInterval) -> ZmxResult
}

extension ZmxRunning {
    public func run(_ arguments: [String], environment: [String: String] = [:], workingDirectory: String? = nil,
                    timeout: TimeInterval) -> ZmxResult {
        run(arguments, environment: environment, workingDirectory: workingDirectory, timeout: timeout)
    }

    /// Off the caller's executor, so a slow `zmx list` does not hold the main actor.
    public func runInBackground(_ arguments: [String], environment: [String: String] = [:],
                                workingDirectory: String? = nil, timeout: TimeInterval) async -> ZmxResult {
        await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: run(arguments, environment: environment,
                                                   workingDirectory: workingDirectory, timeout: timeout))
            }.start()
        }
    }
}

/// Mirrors the app's `ZmxClient.run`: a semaphore deadline, SIGTERM, then SIGKILL after the grace.
/// Spawns and reaps the child itself: corelibs `Process` on Linux reports termination only once every
/// descendant holding its inherited descriptors has exited, and `zmx run` leaves a daemon behind.
public struct ProcessZmxRunner: ZmxRunning {
    public static let terminationGrace: TimeInterval = 0.25

    private let executable: String
    private let zmxDirectory: String
    private let baseEnvironment: [String: String]

    public init(executable: String, zmxDirectory: String,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.zmxDirectory = zmxDirectory
        self.baseEnvironment = baseEnvironment
    }

    public func run(_ arguments: [String], environment: [String: String], workingDirectory: String?,
                    timeout: TimeInterval) -> ZmxResult {
        // A headless child owns its routing; the server may itself be running inside a remote pane.
        let inherited = baseEnvironment.filter { !$0.key.hasPrefix("AGTERM_") && $0.key != "AGTERMCTL" }
        var merged = inherited.merging(environment) { $1 }
        merged["ZMX_DIR"] = zmxDirectory
        merged.removeValue(forKey: "ZMX_SESSION")
        merged.removeValue(forKey: "ZMX_SESSION_PREFIX")
        // drained while waiting: zmx writes its listing row by row and can fill the pipe before it exits
        let capture: OutputCapture
        do {
            capture = try OutputCapture()
        } catch {
            return .launchFailed(error.localizedDescription)
        }
        let pid: pid_t
        switch ChildProcess.spawn(executable, arguments: arguments, environment: merged.map { "\($0.key)=\($0.value)" },
                                  workingDirectory: workingDirectory, output: (capture.stdoutWrite, capture.stderrWrite)) {
        case .running(let spawned):
            pid = spawned
        case .failed(let reason):
            capture.cancel()
            return .launchFailed(reason)
        }
        capture.didLaunch()
        let exit = ChildExit(pid: pid)
        guard let status = exit.wait(until: .now() + timeout) else {
            kill(pid, SIGTERM)
            if exit.wait(until: .now() + Self.terminationGrace) == nil {
                kill(pid, SIGKILL)
                _ = exit.wait(until: .distantFuture)
            }
            capture.cancel()
            return .timedOut
        }
        // a write end inherited by a descendant holds EOF back; a miss is a failed call, not a short one
        guard let output = capture.collect(until: .now() + Self.terminationGrace) else { return .timedOut }
        guard status == 0 else { return .failed(status, output.stderr) }
        return .ok(output.stdout)
    }
}

private enum ChildProcess {
    enum Spawned {
        case running(pid_t)
        case failed(String)
    }

    /// The child gets /dev/null for stdin, the two pipe write ends, no other descriptor of ours, and default signals.
    static func spawn(_ executable: String, arguments: [String], environment: [String], workingDirectory: String?,
                      output: (stdout: Int32, stderr: Int32)) -> Spawned {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output.stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, output.stderr, 2)
        if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }
        // the caller may be a dispatch worker, which blocks most signals; a daemon inheriting that mask
        // outlives `zmx kill` and ignores SIGTERM
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var flags = Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard error == 0 else { return .failed("\(executable): \(String(cString: strerror(error)))") }
        return .running(pid)
    }
}

/// Reaps one child on its own thread, so the deadline is a semaphore wait on any executor. Not a global-queue
/// job: that pool does not grow while its workers block, and a starved reaper turns every call into a timeout.
private final class ChildExit: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    // written only by the reaping thread before `finished` is signalled
    private var status: Int32 = 0

    init(pid: pid_t) {
        Thread { [self] in
            var raw: Int32 = 0
            var reaped = waitpid(pid, &raw, 0)
            while reaped == -1 && errno == EINTR { reaped = waitpid(pid, &raw, 0) }
            let signal = raw & 0x7f
            status = reaped == -1 ? -1 : signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            finished.signal()
        }.start()
    }

    /// The exit status, 128 plus the signal number for a killed child, -1 when it could not be reaped, or nil when `deadline` passed first.
    func wait(until deadline: DispatchTime) -> Int32? {
        guard finished.wait(timeout: deadline) == .success else { return nil }
        finished.signal()
        return status
    }
}

/// stdout and stderr, drained by one thread of its own that polls both read ends. Not `DispatchIO`, as the app's
/// `ProcessOutputCapture` does: its reads run on the global pool, which does not grow while its workers block, and
/// a busy process then saw EOF seconds late. A descendant holding a write end costs a cancelled poll loop.
private final class OutputCapture: @unchecked Sendable {
    struct SetupError: LocalizedError {
        let errorDescription: String?
    }

    let stdoutWrite: Int32
    let stderrWrite: Int32
    private var writeFDs: [Int32]
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    // written only by the drain thread before `finished` is signalled, and read only after a successful wait
    private var output: [Data] = [Data(), Data()]
    private var failed = false

    init() throws {
        var fds: [Int32] = []
        func pipePair() throws -> (read: Int32, write: Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw OutputCapture.setupError("pipe", unwinding: fds) }
            fds += pair
            for fd in pair where fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 {
                throw OutputCapture.setupError("FD_CLOEXEC", unwinding: fds)
            }
            return (pair[0], pair[1])
        }
        let out = try pipePair()
        let err = try pipePair()
        stdoutWrite = out.write
        stderrWrite = err.write
        writeFDs = [out.write, err.write]
        Thread { [self] in drain([out.read, err.read]) }.start()
    }

    func didLaunch() {
        closeWriteEnds()
    }

    func cancel() {
        lock.withLock { cancelled = true }
        closeWriteEnds()
    }

    /// Both streams through EOF, or nil when either missed `deadline` or a read failed. A miss cancels the drain.
    func collect(until deadline: DispatchTime) -> (stdout: String, stderr: String)? {
        guard finished.wait(timeout: deadline) == .success else {
            cancel()
            return nil
        }
        finished.signal()
        guard !failed else { return nil }
        return (String(decoding: output[0], as: UTF8.self), String(decoding: output[1], as: UTF8.self))
    }

    private func drain(_ fds: [Int32]) {
        var buffers = [Data(), Data()]
        var open = [true, true]
        var readFailed = false
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while open.contains(true), !lock.withLock({ cancelled }) {
            var polls = fds.indices.filter { open[$0] }.map { pollfd(fd: fds[$0], events: Int16(POLLIN), revents: 0) }
            // the tick bounds how long a cancelled drain outlives its call
            let ready = poll(&polls, nfds_t(polls.count), 50)
            if ready < 0 {
                if errno == EINTR { continue }
                readFailed = true
                break
            }
            for entry in polls where entry.revents != 0 {
                guard let index = fds.firstIndex(of: entry.fd) else { continue }
                let count = read(entry.fd, &chunk, chunk.count)
                if count > 0 {
                    buffers[index].append(contentsOf: chunk[0..<count])
                } else if count == 0 || errno != EINTR {
                    readFailed = readFailed || count < 0
                    open[index] = false
                }
            }
        }
        fds.forEach { close($0) }
        output = buffers
        failed = readFailed
        finished.signal()
    }

    private func closeWriteEnds() {
        lock.withLock {
            for fd in writeFDs { close(fd) }
            writeFDs = []
        }
    }

    private static func setupError(_ step: String, unwinding fds: [Int32]) -> SetupError {
        let message = String(cString: strerror(errno))
        for fd in fds { close(fd) }
        return SetupError(errorDescription: "\(step): \(message)")
    }
}
