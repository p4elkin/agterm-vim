import ArgumentParser
import Foundation
import agtermCore

/// The overlay-redirect CLI surface: `session.pairing`, the redirect toggle, and the ssh leg of the
/// two-phase open. A new file because `SessionCommands.swift` sits against the 1000-line lint limit. The
/// feature itself is described in `.claude/rules/overlay-redirect.md`.
///
/// Note the name: this `OverlayRedirect` is the CLI command group, and it SHADOWS agtermCore's
/// `OverlayRedirect` decision enum inside this file. Nothing here needs the decision — the app runs it and
/// answers with `ControlOverlayRedirect` — but anything that does must spell it `agtermCore.OverlayRedirect`.
struct OverlayRedirect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overlay-redirect",
        abstract: "Overlay-redirect pairing and toggle commands.",
        subcommands: [Pairing.self, Toggle.self]
    )
}

// MARK: - toggle

/// `agtermctl overlay-redirect toggle [on|off|toggle]` — whether `session.overlay.open` may redirect to/from
/// a paired machine. App-wide, no `--window`, mirroring `NormalMode`'s `[on|off|toggle]` shape. Unlike
/// normal mode this PERSISTS across a restart (`OverlayRedirectController`), so the mirror job or a login
/// hook can arm it once rather than every launch.
struct Toggle: RequestCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Overlay redirect (on|off|toggle).",
        discussion: """
        Turns the overlay-redirect toggle on or off. While it is on, `session.overlay.open` redirects an \
        overlay to the paired machine you are watching from — the mirrored row's workstation, or a \
        watching laptop's row — instead of always opening where the command ran. See `session.pairing` \
        for the two fields this reads.

        Persisted: the setting survives a restart, unlike normal mode.
        """
    )
    @Argument(help: "Mode: on, off, or toggle (default).") var mode: String = "toggle"
    @OptionGroup var options: BasicOptions

    func validate() throws {
        guard ["on", "off", "toggle"].contains(mode) else {
            throw ValidationError("mode must be on, off, or toggle")
        }
    }

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .overlayRedirectToggle, args: ControlArgs(mode: mode))
    }
}

// MARK: - pairing

struct Pairing: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set or clear a session's overlay-redirect pairing (mirrors or viewer).",
        subcommands: [Mirrors.self, Viewer.self]
    )

    /// `agterm-zmx-mirror` calls this on the LAPTOP's row when it creates it, so `session.overlay.open`
    /// there wraps the program in ssh back to the workstation instead of opening it where the row already
    /// is. See `OverlayRedirect.swift` (the decision) and `Session.mirrorsSession` (the field).
    struct Mirrors: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set (or clear) which workstation session this row mirrors.",
            discussion: """
            overlay-redirect pairing mirrors --host H --session S     this row mirrors session S on host H
            overlay-redirect pairing mirrors --host H --session S --cwd D
                                                                     …and it is sitting in directory D
            overlay-redirect pairing mirrors --clear                  drop the pairing (mirrors nothing)

            Read back on `tree` as `mirrorsSession`. A mirrored row wins over a viewer pairing on the same
            session: the overlay is already on the machine being looked at, so redirecting it away would
            move it off that machine.

            `--cwd` is the remote session's own directory, re-asserted every mirror pass. Without it a
            redirected overlay runs in whatever directory the CLI process is in, which on a mirrored row is
            always $HOME — a path that exists on both machines, so the mistake is silent.
            """)
        @Option(name: .long, help: "The host running the real session.") var host: String?
        @Option(name: .long, help: "The session key on that host.") var session: String?
        @Option(name: .long, help: "That session's working directory on that host.") var cwd: String?
        @Flag(name: .long, help: "Drop the pairing (this row mirrors nothing).") var clear = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        // exactly one form: --clear alone, or --host with --session (--cwd optional); the dispatcher enforces
        // the same rule server-side (a raw socket client bypasses this), so reject early for a clean usage error.
        func validate() throws {
            if clear {
                guard host == nil, session == nil, cwd == nil else {
                    throw ValidationError("--clear takes no --host, --session or --cwd")
                }
            } else {
                guard let host, !host.isEmpty else {
                    throw ValidationError("pairing mirrors requires --host (or --clear)")
                }
                guard let session, !session.isEmpty else {
                    throw ValidationError("pairing mirrors requires --session")
                }
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionPairing, target: target.target,
                           args: options.withWindow(ControlArgs(name: clear ? nil : session,
                                                                 cwd: clear ? nil : cwd,
                                                                 mode: "mirrors",
                                                                 host: clear ? "" : host)))
        }
    }

    /// The laptop's mirror job calls this on the WORKSTATION session, over the ssh connection it already
    /// opens every pass — the confirmation time is stamped by the receiving host, not sent, so the two
    /// machines' clocks never need to agree. See `Session.viewer` and `OverlayRedirect.stalenessWindow`.
    struct Viewer: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set (or clear) which remote agterm is watching this session.",
            discussion: """
            overlay-redirect pairing viewer --host H --row R     host H, row R is watching this session
            overlay-redirect pairing viewer --clear              drop the pairing (nothing is watching)

            Stale after twice the mirror interval (`OverlayRedirect.stalenessWindow`), so a laptop that
            closes its lid without cleaning up eventually falls back to a local overlay on its own.
            """)
        @Option(name: .long, help: "The host now watching this session.") var host: String?
        @Option(name: .long, help: "The watching row's session key on that host.") var row: String?
        @Flag(name: .long, help: "Drop the pairing (nothing is watching).") var clear = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if clear {
                guard host == nil, row == nil else {
                    throw ValidationError("--clear takes no --host or --row")
                }
            } else {
                guard let host, !host.isEmpty else {
                    throw ValidationError("pairing viewer requires --host (or --clear)")
                }
                guard let row, !row.isEmpty else {
                    throw ValidationError("pairing viewer requires --row")
                }
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionPairing, target: target.target,
                           args: options.withWindow(ControlArgs(name: clear ? nil : row,
                                                                 mode: "viewer",
                                                                 host: clear ? "" : host)))
        }
    }
}

// MARK: - the ssh leg

/// Everything the redirect does outside the control socket, injected so the whole two-phase flow is
/// testable without a network, a real `/tmp` file or a real ssh.
struct OverlayRedirectEnvironment: Sendable {
    /// This machine's name as reachable FROM the viewer. Nil means there is nothing to ssh back to, which
    /// falls back to a plain local overlay.
    var sourceHost: @Sendable () -> String?
    /// This process's working directory, which for a chord-spawned `agtermctl` IS the session's own — the
    /// default the app would have used had the overlay opened here.
    var currentDirectory: @Sendable () -> String
    /// Writes the ssh-back script and returns its path.
    var writeScript: @Sendable (_ cwd: String, _ command: String) throws -> String
    /// Deletes a script `writeScript` wrote that nothing will ever run — only the script that DOES run
    /// cleans itself up.
    var removeScript: @Sendable (_ path: String) -> Void
    /// Runs ssh to completion and returns its exit status.
    var runSsh: @Sendable (_ arguments: [String]) -> Int32

    static let live = OverlayRedirectEnvironment(
        sourceHost: { OverlayRedirectSsh.resolveSourceHost() },
        currentDirectory: { FileManager.default.currentDirectoryPath },
        writeScript: { try OverlayRedirectSsh.writeSourceScript(cwd: $0, command: $1) },
        removeScript: { OverlayRedirectSsh.removeSourceScript(path: $0) },
        runSsh: { OverlayRedirectSsh.runSsh($0) })
}

/// The command lines the redirect builds, ported from `~/dev/agterm-agents/bin/agterm-remote-overlay` —
/// the escaping is copied from a script that already solved it, deliberately not redesigned.
enum OverlayRedirectSsh {
    /// An asleep laptop then costs two seconds rather than a full TCP timeout.
    static let connectTimeout = "2"
    /// ssh reserves this status for its OWN failures, so it is the one status that means "the far side was
    /// not reached" rather than "the program exited with this".
    static let sshFailureStatus: Int32 = 255

    /// A non-interactive ssh lands with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, where `agtermctl` reads as
    /// "command not found". The far side is therefore always named by absolute path.
    static var remoteAgtermctl: String {
        let override = ProcessInfo.processInfo.environment["AGTERM_REMOTE_AGTERMCTL"] ?? ""
        return override.isEmpty ? "/opt/homebrew/bin/agtermctl" : override
    }

    /// A value bound for DOUBLE quotes nested one shell-eval deeper than plain text. The backslash pass runs
    /// first, so an already-escaped character does not lose its own backslash.
    static func dqEscape(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: #"\"#, with: #"\\"#)
        escaped = escaped.replacingOccurrences(of: "\"", with: #"\""#)
        escaped = escaped.replacingOccurrences(of: "$", with: #"\$"#)
        return escaped.replacingOccurrences(of: "`", with: #"\`"#)
    }

    /// Single-quote a value so the eval it passes through cannot touch it at all. `agtermCore`'s own
    /// POSIX quoting, not a fifth copy of it.
    static func sqQuote(_ value: String) -> String { CLIInstall.shellQuote(value) }

    /// The script that runs the caller's command back on THIS host once the viewer's overlay ssh's over.
    ///
    /// The command lands in a file rather than inline because the string that carries it already crosses one
    /// ssh hop and one internal `sh -c eval` before it can run anything, and the caller's command must still
    /// get exactly ONE shell parse to keep the contract it has with a plain local overlay. A file written
    /// byte for byte, with no shell re-parsing at write time, absorbs the two extra layers. The trigger then
    /// only has to say "ssh back, then run this path" — two plain tokens, safe to quote with no escaping.
    ///
    /// Self-deleting and status-preserving, so a caller's `--block` still sees the program's real exit code.
    /// ⚠️ The failed-`cd` arm deletes the directory too: a far-side path that no longer exists is the one
    /// failure the script itself can see, and an early `exit 1` before the `rm -rf` leaks the directory for
    /// good — nothing else ever revisits it.
    static func sourceScript(cwd: String, command: String, directory: String) -> String {
        """
        #!/bin/sh
        cd "\(dqEscape(cwd))" || { rm -rf -- "\(directory)"; exit 1; }
        \(command)
        status=$?
        rm -rf -- "\(directory)"
        exit "$status"

        """
    }

    /// The prefix every generated script directory carries, so `removeSourceScript` can refuse a path that
    /// did not come from here.
    static let scriptDirectoryPrefix = "agterm-overlay-redirect-"

    /// ⚠️ Not `/tmp`. `NSTemporaryDirectory()` is per-user on macOS (`/var/folders/…`, mode 0700, and
    /// reachable by the same user over the ssh-back), so no other local account can pre-create the
    /// directory, plant a symlink at the script path, or swap the file between this write and the
    /// `sh <path>` the viewer ssh's back to run. The random component is on the DIRECTORY, not the file
    /// name: two invocations must never share a directory, since the first script to finish `rm -rf`s it.
    /// `withIntermediateDirectories: false` makes an already-existing directory an error rather than one
    /// this process adopts.
    static func writeSourceScript(cwd: String, command: String) throws -> String {
        sweepAbandonedScriptDirectories()
        let directory = NSTemporaryDirectory() + scriptDirectoryPrefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let path = "\(directory)/run.sh"
        // written as raw bytes: the command is stored completely opaque, never re-parsed at write time.
        try Data(sourceScript(cwd: cwd, command: command, directory: directory).utf8)
            .write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    /// Clean up a script the viewer never got to run: the script's own `rm -rf` only fires on the path that
    /// really executed, so every fallback would otherwise leave its directory behind forever. Guarded on the
    /// generated prefix, so a path from anywhere else can never delete its parent directory.
    static func removeSourceScript(path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        guard (directory as NSString).lastPathComponent.hasPrefix(scriptDirectoryPrefix) else { return }
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// A directory this old was written for a redirect that never ran: the viewer answered ok, so nothing
    /// deleted it here, and then its overlay was closed, its machine slept, or the ssh back never happened.
    /// Only the script that really runs cleans up after itself, so without this every such redirect leaves a
    /// directory behind forever. A day is far longer than any overlay lives, so a pending one is never swept.
    static let abandonedScriptAge: TimeInterval = 24 * 60 * 60

    static func sweepAbandonedScriptDirectories(now: Date = Date()) {
        let root = NSTemporaryDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in names where name.hasPrefix(scriptDirectoryPrefix) {
            let path = root + name
            let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
            guard let created, now.timeIntervalSince(created) > abandonedScriptAge else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// What the viewer's overlay actually runs: ssh back here, then the generated script. Two plain tokens.
    static func sshBackTrigger(sourceHost: String, scriptPath: String) -> String {
        "ssh -o ConnectTimeout=\(connectTimeout) -t \"\(dqEscape(sourceHost))\" \(sqQuote("sh \(scriptPath)"))"
    }

    /// The mirror-of wrapper: the overlay is already on the machine being looked at, so only the program
    /// travels. Single-quoting the remote half keeps the local eval away from it, leaving the caller's
    /// command the one parse the far side's shell gives it.
    static func mirroredCommand(host: String, cwd: String?, command: String) -> String {
        let remote = cwd.map { #"cd "\#(dqEscape($0))" && \#(command)"# } ?? command
        return "ssh -o ConnectTimeout=\(connectTimeout) -t \(sqQuote(host)) \(sqQuote(remote))"
    }

    /// `-n` so ssh cannot eat the caller's stdin.
    static func sshArguments(host: String, remoteCommand: String) -> [String] {
        ["-n", "-o", "ConnectTimeout=\(connectTimeout)", "--", host, remoteCommand]
    }

    static func runSsh(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        do { try process.run() } catch { return sshFailureStatus }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Both machines read the SAME path — the laptop and the workstation each name themselves in it, so
    /// whichever side is asked "what do I ssh back to" answers with a name that resolves off the LAN too.
    /// `$AGTERM_OVERLAY_REDIRECT_CONFIG` moves it, and is honoured here as well as in `agterm-zmx-mirror`:
    /// exporting it must not point the two halves of one contract at two different files.
    static var defaultConfigPath: String {
        let override = ProcessInfo.processInfo.environment["AGTERM_OVERLAY_REDIRECT_CONFIG"] ?? ""
        return override.isEmpty ? NSHomeDirectory() + "/.config/agterm-overlay-redirect.conf" : override
    }

    /// This host's name as the viewer reaches it, in order: an explicit override, the config file, then the
    /// local host name (LAN-only, but keeps today's behaviour for anyone who configures nothing). The
    /// environment overrides carry an existing `agterm-remote-overlay` configuration over. A trailing dot is
    /// stripped — Tailscale's own DNS name carries one, ssh usage never does.
    static func resolveSourceHost(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  hostName: String = ProcessInfo.processInfo.hostName,
                                  configPath: String = defaultConfigPath) -> String? {
        for key in ["AGTERM_OVERLAY_SOURCE_HOST", "AGTERM_REMOTE_OVERLAY_SOURCE_HOST"] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        if let configured = readConfiguredSelfHost(path: configPath), !configured.isEmpty {
            return configured
        }
        let name = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        return name.isEmpty ? nil : name
    }

    /// `self=<name>`, one key per line. THE PARSING RULES, which `agterm-zmx-mirror`'s
    /// `read_overlay_redirect_self_host` implements character for character — the two must agree, or the
    /// laptop and the workstation disagree about what this machine is called and the ssh back goes nowhere:
    ///
    /// 1. `#` starts a comment, even mid-line; what is left is the line.
    /// 2. A blank (or all-whitespace) line is skipped, and so is a line with no `=`.
    /// 3. Key and value are trimmed of ALL surrounding whitespace — tabs and a CRLF's `\r` included, so a
    ///    tab-indented line is accepted and a file written on Windows does not yield a host name with a
    ///    trailing carriage return.
    /// 4. The FIRST `self=` line wins and parsing stops, its value empty or not. A second one is never read,
    ///    and an empty first value falls through to the next source rather than to the second line.
    /// 5. A missing file means "not configured", not an error.
    static func readConfiguredSelfHost(path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hashIndex = line.firstIndex(of: "#") { line = String(line[..<hashIndex]) }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "self" else { continue }
            return line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// A name that cannot work for an ssh back FROM another machine: an mDNS `.local` name resolves only on
    /// the same LAN, and a bare host name with no dots resolves only through whatever the far side's own
    /// search domain happens to be. Both are what `hostname` returns when nothing is configured, which is
    /// why a fallback names the config file rather than just saying the redirect failed.
    static func isLanOnly(_ host: String) -> Bool {
        host.hasSuffix(".local") || !host.contains(".")
    }
}

extension Session.Overlay.Open {
    /// Phase one, then whatever it answers. `session.overlay.open` both decides and opens, so the decision
    /// cannot simply be returned: on either redirect outcome the app opens NOTHING and answers with the
    /// outcome, and the resolved re-send carries `resolved` so it cannot loop back into a fresh decision.
    func runRedirecting(environment: OverlayRedirectEnvironment,
                        send: (ControlRequest) throws -> ControlResponse) throws {
        let opened = try send(makeRequest())
        guard opened.ok, let result = opened.result, let redirect = result.overlayRedirect else {
            try finishLocally(opened, send: send)
            return
        }
        switch redirect.outcome {
        case .mirrorOf:
            // ⚠️ The cwd must reach the far side, `--cwd` given or not, and the PAIRING's is the one to trust.
            // A chord-spawned `agtermctl` inherits the ROW's directory, and a mirrored row never learns the
            // remote shell's: libghostty drops its OSC 7 as not local, so the row keeps the `--cwd "$HOME"`
            // the mirror job pinned at creation. `$HOME` exists on both machines, so the `cd` succeeded and
            // the overlay opened in the wrong directory with nothing to show for it. The mirror job records
            // the real one on the pairing instead, refreshed every pass. An explicit `--cwd` still wins: the
            // caller named that path deliberately. A pairing from an older mirror job carries none, and then
            // the process directory is all there is, exactly as before.
            let fallbackCwd = cwd == nil && redirect.cwd == nil
            if fallbackCwd {
                // the one case where the wrong directory is otherwise SILENT: $HOME exists on the far side
                // too, so the `cd` succeeds and lazygit simply opens somewhere else.
                warn("""
                    this row records no directory for \(redirect.host) (an older agterm-zmx-mirror here, or a \
                    pairing restored from a snapshot); opening in this process's directory instead
                    """)
            }
            let wrapped = OverlayRedirectSsh.mirroredCommand(
                host: redirect.host,
                cwd: cwd ?? redirect.cwd ?? environment.currentDirectory(),
                command: command)
            // no cwd on the re-send: it is now baked into the remote half, and a far-side path need not
            // exist here — a missing one would fail the local overlay's own spawn.
            try finishLocally(try send(try resolvedRequest(command: wrapped, cwd: nil, target: result.id)),
                              send: send)
        case .watchedBy:
            try sendToViewer(redirect, id: result.id, environment: environment, send: send)
        }
    }

    /// The remote `agtermctl session overlay open`, with the caller's own flags carried over. `--block` in
    /// particular is carried, never reimplemented: the remote side blocks and its status returns through ssh.
    ///
    /// ⚠️ `--resolved` is carried too. The viewer's row almost always has a `mirrorsSession` of its own (it
    /// is a mirrored row, and its toggle must be on for this direction to work at all), so without it the
    /// far side re-enters the decision, answers `mirror-of` and wraps the trigger in a SECOND ssh — back to
    /// the machine that just sent it, which would then have to ssh to itself.
    func remoteOpenCommand(trigger: String, row: String) -> String {
        var line = OverlayRedirectSsh.remoteAgtermctl + " session overlay open"
        line += " \"\(OverlayRedirectSsh.dqEscape(trigger))\" --target \(OverlayRedirectSsh.sqQuote(row))"
        line += " --resolved"
        if wait { line += " --wait" }
        if block { line += " --block" }
        if follow { line += " --follow" }
        if let sizePercent { line += " --size-percent '\(sizePercent)'" }
        if let backgroundColor { line += " --background-color \(OverlayRedirectSsh.sqQuote(backgroundColor))" }
        if let pane { line += " --pane \(OverlayRedirectSsh.sqQuote(pane))" }
        if options.json { line += " --json" }
        return line
    }

    private func sendToViewer(_ redirect: ControlOverlayRedirect,
                              id: String?,
                              environment: OverlayRedirectEnvironment,
                              send: (ControlRequest) throws -> ControlResponse) throws {
        guard let row = redirect.row, let sourceHost = environment.sourceHost() else {
            // a `watched-by` answer with no row is a protocol violation, and no source host means there is
            // nothing for the viewer to ssh back to. Neither can be redirected; open here, with a word about
            // it — a redirect that quietly does not happen is the failure mode this feature exists to fix.
            if redirect.row != nil { warn(sourceHostAdvice("this machine has no name to ssh back to")) }
            try openWithoutRedirect(id: id, send: send)
            return
        }
        let script: String
        do {
            script = try environment.writeScript(cwd ?? environment.currentDirectory(), command)
        } catch {
            // a local temp-directory problem, not a network condition, so it gets a message — but the chord
            // still has to produce an overlay somewhere.
            FileHandle.standardError.write(
                Data("agtermctl: could not write the ssh-back script: \(error)\n".utf8))
            try openWithoutRedirect(id: id, send: send)
            return
        }
        let trigger = OverlayRedirectSsh.sshBackTrigger(sourceHost: sourceHost, scriptPath: script)
        let status = environment.runSsh(
            OverlayRedirectSsh.sshArguments(host: redirect.host,
                                            remoteCommand: remoteOpenCommand(trigger: trigger, row: row)))
        if status == 0 { return }
        // Without `--block` the remote `agtermctl` returns as soon as the OPEN is done, so any nonzero
        // status there means the open itself failed (an older agtermctl over there, the row closed inside
        // the 40-second staleness window, `--pane right` on a row that is not split) and the overlay must
        // still appear somewhere. Under `--block` the status is the remote PROGRAM's own and must pass
        // through, so only ssh's reserved 255 can be read as "not reached" — a remote program that really
        // exits 255 is indistinguishable from that, and its command runs a second time here.
        guard !block || status == OverlayRedirectSsh.sshFailureStatus else { throw ExitCode(rawValue: status) }
        var message = "the overlay could not open on \(redirect.host) (ssh exited \(status)); opening here instead"
        if status == OverlayRedirectSsh.sshFailureStatus, OverlayRedirectSsh.isLanOnly(sourceHost) {
            // ⚠️ The unconfigured case: `hostname` answers with an mDNS `.local` name, the viewer's ssh back
            // never resolves off the LAN, and every redirect degrades to a local overlay. Say which file
            // fixes it rather than letting the feature look broken.
            message = sourceHostAdvice("\(redirect.host) could not run the overlay (ssh exited \(status)), "
                                       + "and this machine calls itself \"\(sourceHost)\"")
        }
        warn(message)
        environment.removeScript(script)
        // The viewer never ran the trigger, so the pairing pointing at it is not usable. Clearing it turns
        // the pill grey now instead of leaving it red for the rest of the staleness window (or forever, if
        // only this direction of ssh is broken); the next mirror pass re-arms it if the viewer is really
        // there. Best-effort: an older agterm on this side simply keeps the stale pairing.
        if let id { _ = try? send(clearViewerRequest(id: id)) }
        try openWithoutRedirect(id: id, send: send)
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("agtermctl: \(message)\n".utf8))
    }

    /// Every "the redirect did not happen because of this machine's own name" message ends the same way:
    /// what went wrong, then the one file that fixes it.
    private func sourceHostAdvice(_ problem: String) -> String {
        "\(problem) — write self=<name reachable from the other machine> into "
            + "\(OverlayRedirectSsh.defaultConfigPath) on both machines; opening here instead"
    }

    /// `overlay-redirect pairing viewer --clear`'s wire form: mode `viewer` with an empty host.
    private func clearViewerRequest(id: String) -> ControlRequest {
        ControlRequest(cmd: .sessionPairing, target: id,
                       args: options.withWindow(ControlArgs(mode: "viewer", host: "")))
    }

    /// The fallback: the caller's own command, opened here, with `resolved` set so the app does not decide
    /// again and send it straight back to the viewer that just failed to answer.
    private func openWithoutRedirect(id: String?, send: (ControlRequest) throws -> ControlResponse) throws {
        try finishLocally(try send(try resolvedRequest(command: command, cwd: cwd, target: id)), send: send)
    }

    /// The re-send is the caller's OWN request with three fields moved, never a second hand-written copy of
    /// the option set: a new `session overlay open` flag then reaches both redirect arms with no edit here.
    private func resolvedRequest(command: String, cwd: String?, target: String?) throws -> ControlRequest {
        let base = try makeRequest()
        var args = base.args ?? ControlArgs()
        args.command = command
        args.cwd = cwd
        args.resolved = true
        return ControlRequest(cmd: .sessionOverlayOpen, target: target ?? base.target, args: args)
    }

    /// The desk path's own tail, unchanged: print the response, or poll the overlay out for `--block`.
    private func finishLocally(_ response: ControlResponse,
                               send: (ControlRequest) throws -> ControlResponse) throws {
        guard block else {
            try printAndCheck(response)
            return
        }
        guard response.ok, let id = response.result?.id else {
            SocketClient.printResponse(response, json: options.json)
            throw ExitCode.failure
        }
        while true {
            let res = try send(resultRequest(id: id))
            if res.ok {
                if options.json { SocketClient.printResponse(res, json: true) }
                // a successful result must carry the status; its absence is a protocol violation, not success.
                guard let code = res.result?.exitCode else {
                    FileHandle.standardError.write(Data("error: result missing exit code\n".utf8))
                    throw ExitCode.failure
                }
                throw ExitCode(rawValue: Int32(code))
            }
            if res.error == OverlayResultError.stillRunning {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            SocketClient.printResponse(res, json: options.json)
            throw ExitCode.failure
        }
    }
}
