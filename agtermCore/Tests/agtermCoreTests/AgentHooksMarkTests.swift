import Foundation
import Testing

// Executes the SHIPPED status wrapper with a stub agtermctl: the fork-only `mark` branch must reach
// `session mark` with the same socket/target resolution as a status call. Never runs the installer.
struct AgentHooksMarkTests {
    private static var wrapper: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/agterm-agent-status.sh")
            .path
    }

    private func run(_ args: [String], environment: [String: String]) throws -> (calls: [String], exit: Int32) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-mark-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let calls = dir.appendingPathComponent("calls")
        let agtermctl = dir.appendingPathComponent("agtermctl")
        try "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(calls.path)'\n"
            .write(to: agtermctl, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agtermctl.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Self.wrapper] + args
        var env = environment
        env["AGTERMCTL"] = agtermctl.path
        env["PATH"] = "/usr/bin:/bin"
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let lines = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (lines, proc.terminationStatus)
    }

    @Test func markCallsSessionMarkWithTargetAndSocket() throws {
        // AGTERM_PANE is set but must NOT be forwarded: the mark always lands in the session's main pty
        let result = try run(["mark"], environment: [
            "AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/agterm.sock", "AGTERM_PANE": "right",
        ])
        #expect(result.exit == 0)
        #expect(result.calls == ["session mark --target sid --socket /tmp/agterm.sock"])
    }

    @Test func markWithoutSocketOmitsTheOption() throws {
        let result = try run(["mark"], environment: ["AGTERM_SESSION_ID": "sid"])
        #expect(result.exit == 0)
        #expect(result.calls == ["session mark --target sid"])
    }

    @Test func markOutsideAgtermIsASilentNoOp() throws {
        let result = try run(["mark"], environment: [:])
        #expect(result.exit == 0)
        #expect(result.calls.isEmpty)
    }

    @Test func statusPathStillRoutesToSessionStatus() throws {
        let result = try run(["active", "--blink"], environment: [
            "AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/agterm.sock",
        ])
        #expect(result.exit == 0)
        #expect(result.calls == ["session status active --target sid --socket /tmp/agterm.sock --blink"])
    }
}
