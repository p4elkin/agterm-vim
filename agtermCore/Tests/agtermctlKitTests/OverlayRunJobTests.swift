import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

@Suite(.serialized)
struct OverlayRunJobTests {
    final class FakeOrigin: @unchecked Sendable {
        let helper: Int32
        let origin: Int32
        private let lock = NSLock()
        private var received: [OverlayJobFrame] = []
        private let done = DispatchSemaphore(value: 0)

        init(helper: Int32, origin: Int32) {
            self.helper = helper
            self.origin = origin
        }

        convenience init() {
            var pair: [Int32] = [-1, -1]
            #if canImport(Darwin)
            socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
            var noSigPipe: Int32 = 1
            for fd in pair { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) }
            #else
            socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair)
            #endif
            self.init(helper: pair[0], origin: pair[1])
        }

        func serve(reply: String, context: OverlayLaunchContext?) {
            Thread { [self] in
                _ = readLine()
                write(reply + "\n")
                if let context, let line = try? OverlayJobFrame.context(context).line() {
                    write(String(decoding: line, as: UTF8.self))
                }
                while let line = readLine() {
                    if let frame = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) {
                        lock.withLock { received.append(frame) }
                    }
                }
                done.signal()
            }.start()
        }

        func send(_ frame: OverlayJobFrame) {
            guard let line = try? frame.line() else { return }
            write(String(decoding: line, as: UTF8.self))
        }

        func frames() -> [OverlayJobFrame] {
            // Linux wakes the runner's blocked read, and so ends the stream, only on shutdown
            shutdown(helper, Int32(SHUT_RDWR))
            close(helper)
            _ = done.wait(timeout: .now() + 5)
            close(origin)
            return lock.withLock { received }
        }

        private func write(_ text: String) {
            _ = StreamBridge.writeAll(origin, Data(text.utf8))
        }

        private func readLine() -> Data? {
            var line = Data()
            var byte: UInt8 = 0
            while true {
                guard read(origin, &byte, 1) == 1 else { return nil }
                if byte == UInt8(ascii: "\n") { return line }
                line.append(byte)
            }
        }
    }

    static let okReply = #"{"ok":true,"result":{"id":"job"}}"#

    static let base = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]

    func context(_ command: String) -> OverlayLaunchContext {
        OverlayLaunchContext(command: command, cwd: "/tmp", sessionEnvironment: ["AGTERM_ENABLED": "1"])
    }

    func gone(_ pid: pid_t) -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return true }
            usleep(20_000)
        }
        return false
    }

    func pidFile() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-run-job-\(UUID().uuidString).pid")
    }

    func readPID(_ path: String) -> pid_t? {
        for _ in 0..<100 {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            usleep(20_000)
        }
        return nil
    }

    @Test func aProgramExitingThreeReportsThreeAndTheHelperExitsThree() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context("exit 3"))
        let runner = OverlayJobRunner(socket: origin.helper)

        let status = runner.run(try runner.claim("job"), baseEnvironment: Self.base)

        #expect(status == 3)
        #expect(origin.frames() == [.started, .exited(3)])
    }

    @Test func aRefusedClaimLaunchesNothing() {
        let origin = FakeOrigin()
        origin.serve(reply: #"{"ok":false,"error":"job not claimable"}"#, context: nil)
        let runner = OverlayJobRunner(socket: origin.helper)

        #expect(throws: SocketClientError.self) { try runner.claim("job") }
        #expect(origin.frames().isEmpty)
    }

    @Test func aCancelFromTheAppEndsTheProgramCanceled() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context("sleep 30"))
        let runner = OverlayJobRunner(socket: origin.helper, grace: 0.3)
        let claimed = try runner.claim("job")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { origin.send(.cancel) }

        let status = runner.run(claimed, baseEnvironment: Self.base)

        #expect(status == 128 + SIGTERM)
        #expect(origin.frames() == [.started, .canceled])
    }

    @Test func aCancelKillsAProgramThatIgnoresTheFirstSignal() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context(#"trap "" TERM; sleep 30"#))
        let runner = OverlayJobRunner(socket: origin.helper, grace: 0.3)
        let claimed = try runner.claim("job")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { runner.cancel() }
        let started = Date()

        let status = runner.run(claimed, baseEnvironment: Self.base)

        #expect(status == 128 + SIGKILL)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(origin.frames() == [.started, .canceled])
    }

    @Test func aReportTheAppNeverGetsLeavesTheHelpersStatusAlone() throws {
        let origin = FakeOrigin()
        defer { close(origin.helper) }
        origin.serve(reply: Self.okReply, context: context("sleep 0.3; exit 5"))
        let runner = OverlayJobRunner(socket: origin.helper)
        let claimed = try runner.claim("job")
        close(origin.origin)

        #expect(runner.run(claimed, baseEnvironment: Self.base) == 5)
    }

    @Test func theProgramDoesNotInheritTheAppConnection() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context("test ! -e /dev/fd/\(origin.helper)"))
        let runner = OverlayJobRunner(socket: origin.helper)

        #expect(runner.run(try runner.claim("job"), baseEnvironment: Self.base) == 0)
        #expect(origin.frames() == [.started, .exited(0)])
    }

    @Test func theTerminalTypeComesFromTheHelpersOwnTerminal() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context(#"test "$TERM" = xterm-kitty"#))
        let runner = OverlayJobRunner(socket: origin.helper)

        var base = Self.base
        base["TERM"] = "xterm-kitty"

        #expect(runner.run(try runner.claim("job"), baseEnvironment: base) == 0)
        #expect(origin.frames() == [.started, .exited(0)])
    }

    @Test func theProgramGetsTheHelpersEnvironmentUnderTheContext() throws {
        let bin = (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-run-job-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let tool = (bin as NSString).appendingPathComponent("agterm-fixture-tool")
        try "#!/bin/sh\nexit 0\n".write(toFile: tool, atomically: true, encoding: .utf8)
        chmod(tool, 0o755)
        let session = UUID()
        let environment = SurfaceEnvironment.session(sessionID: session, windowID: nil, workspaceID: nil,
                                                     socketPath: "/tmp/origin.sock", programVersion: "9.9.9")
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: OverlayLaunchContext(
            command: #"agterm-fixture-tool && test -n "$HOME" && test "$AGTERM_SESSION_ID" = "\#(session.uuidString)""#,
            cwd: "/tmp", sessionEnvironment: environment))
        let runner = OverlayJobRunner(socket: origin.helper)

        let status = runner.run(try runner.claim("job"), baseEnvironment: ["PATH": "\(bin):/usr/bin:/bin", "HOME": "/Users/x",
                                                                           "AGTERM_SESSION_ID": "stale"])

        #expect(status == 0)
        #expect(origin.frames() == [.started, .exited(0)])
    }

    @Test func aCancelEndsTheProgramsDescendantsToo() throws {
        let origin = FakeOrigin()
        let path = pidFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        origin.serve(reply: Self.okReply, context: context("/bin/sleep 60 & echo $! > \(path); wait"))
        let runner = OverlayJobRunner(socket: origin.helper, grace: 0.3)
        let claimed = try runner.claim("job")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { origin.send(.cancel) }

        _ = runner.run(claimed, baseEnvironment: Self.base)

        let descendant = try #require(readPID(path))
        #expect(gone(descendant))
        #expect(origin.frames() == [.started, .canceled])
    }

    @Test func runJobParsesUnderSessionOverlay() throws {
        let command = try #require(try Agtermctl.parseAsRoot(["session", "overlay", "run-job", "job-id"])
            as? agtermctlKit.Session.Overlay.RunJob)

        #expect(command.job == "job-id")
    }

    @Test func aProgramThatCannotStartReportsLaunchFailed() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply,
                     context: OverlayLaunchContext(command: "true", cwd: "/nonexistent-\(UUID().uuidString)",
                                                   sessionEnvironment: [:]))
        let runner = OverlayJobRunner(socket: origin.helper)

        let status = runner.run(try runner.claim("job"), baseEnvironment: Self.base)

        #expect(status == 127)
        guard case .launchFailed? = origin.frames().first else {
            Issue.record("expected launch-failed")
            return
        }
    }

    #if os(Linux)
    @Test func underARealTerminalTheProgramOwnsItReadsItsKeysAndSetsTheExitStatus() throws {
        let helper = try #require(Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agtermctl").path)
        try #require(FileManager.default.isExecutableFile(atPath: helper))
        let cwd = (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-run-job-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let path = "/tmp/agterm-rj-\(UUID().uuidString.prefix(8)).sock"
        let listener = try Self.listen(at: path)
        defer { close(listener); unlink(path) }
        // the program is stopped by SIGTTIN on its read unless it leads the terminal's foreground group
        let command = #"read -r key; test "$key" = hi || exit 9; test "$(pwd)" = "$EXPECTED_CWD" || exit 8; "#
            + #"stat=$(cat /proc/$$/stat); set -- ${stat#*) }; test "$3" = "$6" || exit 7; exit 4"#
        let accepted = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var origin: FakeOrigin?
        Thread {
            let fd = accept(listener, nil, nil)
            if fd >= 0 {
                origin = FakeOrigin(helper: -1, origin: fd)
                origin?.serve(reply: Self.okReply, context: OverlayLaunchContext(
                    command: command, cwd: cwd, sessionEnvironment: ["EXPECTED_CWD": cwd]))
            }
            accepted.signal()
        }.start()
        let terminal = try PseudoTerminal()
        defer { terminal.close() }

        let pid = try terminal.spawnSessionLeader(["/usr/bin/timeout", "-k", "2", "20", helper,
                                                   "session", "overlay", "run-job", "job", "--socket", path])
        #expect(accepted.wait(timeout: .now() + 10) == .success)
        _ = StreamBridge.writeAll(terminal.primary, Data("hi\n".utf8))
        let status = terminal.drain(until: pid)

        #expect(status == 4)
        #expect(try #require(origin).frames() == [.started, .exited(4)])
    }

    static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, Glibc.listen(fd, 1) == 0 else { throw SocketClientError("test listener failed") }
        return fd
    }

    /// A pty whose secondary side becomes the controlling terminal of a spawned session leader.
    final class PseudoTerminal {
        let primary: Int32
        private let secondary: Int32

        init() throws {
            // the pty calls are behind _XOPEN_SOURCE, which the Glibc module does not set
            primary = open("/dev/ptmx", O_RDWR | O_NOCTTY)
            guard primary >= 0, pty_unlock(primary) == 0, let name = pty_name(primary) else { throw SocketClientError("no pty") }
            secondary = open(String(cString: name), O_RDWR | O_NOCTTY)
            guard secondary >= 0 else { throw SocketClientError("no pty secondary") }
        }

        /// `setsid --ctty` makes the pty the controlling terminal of a new session, as sshd does.
        func spawnSessionLeader(_ argv: [String]) throws -> pid_t {
            let argv = ["/usr/bin/setsid", "--ctty", "--wait"] + argv
            var actions = posix_spawn_file_actions_t()
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            for fd in Int32(0)...2 { posix_spawn_file_actions_adddup2(&actions, secondary, fd) }
            var pid: pid_t = 0
            var pointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
            defer { pointers.forEach { free($0) } }
            let result = posix_spawn(&pid, argv[0], &actions, nil, &pointers, environ)
            _ = Glibc.close(secondary)
            guard result == 0 else { throw SocketClientError("spawn failed: \(result)") }
            return pid
        }

        /// Reads the terminal so the program never blocks on output, until `pid` exits; returns its status.
        func drain(until pid: pid_t) -> Int32 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var status: Int32 = 0
            while waitpid(pid, &status, WNOHANG) == 0 {
                var probe = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
                if poll(&probe, 1, 50) > 0, probe.revents & Int16(POLLIN) != 0 { _ = read(primary, &buffer, buffer.count) }
            }
            return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        }

        func close() { _ = Glibc.close(primary) }
    }
    #endif
}

#if os(Linux)
@_silgen_name("unlockpt") private func pty_unlock(_ fd: Int32) -> Int32
@_silgen_name("ptsname") private func pty_name(_ fd: Int32) -> UnsafeMutablePointer<CChar>?
#endif
