import Foundation

/// How an attach reaches the far side. ssh is the default and the pre-existing behavior; mosh survives
/// roaming and laptop sleep, at the cost of a different argv shape (see `RemoteSession.attachCommand`).
public enum RemoteTransport: Codable, Equatable, Sendable {
    case ssh
    case mosh(server: String?, client: String?)

    /// Wire strings to the enum, shared by the dispatcher and the CLI so both refuse the same values.
    /// `moshServer` and `mosh` are refused outside mosh: each can mean one thing there — the far side's
    /// server, and the LOCAL binary the pane runs. An EMPTY path is refused too, unlike an omitted one: a
    /// shell-quoting bug must not silently ask mosh to find its own server, or the pane its own client,
    /// which is what omitting the flag means. A non-empty one must be `isPlainMoshServer`: mosh
    /// interpolates `--server=` raw into the far side's shell line, and the client path is a command the
    /// pane's own shell runs.
    public static func parse(transport: String?, moshServer: String?, mosh: String? = nil) throws -> RemoteTransport {
        switch transport {
        case nil, "ssh":
            guard moshServer == nil, mosh == nil else { throw RemoteSession.InvocationError.invalidTransport }
            return .ssh
        case "mosh":
            if let moshServer, !RemoteSession.isPlainMoshServer(moshServer) {
                throw RemoteSession.InvocationError.invalidTransport
            }
            if let mosh, !RemoteSession.isPlainMoshServer(mosh) {
                throw RemoteSession.InvocationError.invalidTransport
            }
            return .mosh(server: moshServer, client: mosh)
        default:
            throw RemoteSession.InvocationError.invalidTransport
        }
    }

    /// Why `parse` rejected a wire pair, for the dispatcher and the CLI to print. The spelling is echoed
    /// only when it is plain: `agtermctl` prints this to a terminal, where a control character would act.
    public static func refusalMessage(transport: String?, moshServer: String?, mosh: String? = nil) -> String {
        if let transport, transport != "ssh", transport != "mosh" {
            return "invalid transport: \(RemoteSession.isPlain(transport) ? transport : "") (ssh|mosh)"
        }
        if moshServer != nil, transport != "mosh" {
            return "--mosh-server needs --transport mosh"
        }
        if mosh != nil, transport != "mosh" {
            return "--mosh needs --transport mosh"
        }
        if let moshServer, !RemoteSession.isPlainMoshServer(moshServer) {
            return "invalid mosh-server path"
        }
        return "invalid mosh path"
    }
}

/// The ssh command lines that reach another agterm's zmx daemons. Pure and host-free: callers run what
/// these return, and the app target owns process execution.
public enum RemoteSession {
    public enum InvocationError: Error, Equatable {
        case emptyHost
        case invalidHost
        case invalidSession
        case invalidEndpoint
        case invalidTransport
    }

    /// One ssh invocation running the far side's own `zmx tree`, which returns its attachable sessions
    /// across every open window as a single document.
    ///
    /// `-T` because no pty is wanted, `BatchMode=yes` because a host-key or password prompt would hang a
    /// dispatcher with no way to answer it. `ConnectTimeout` bounds the handshake only — the caller still
    /// needs its own deadline for a remote command that never returns.
    public static func treeCommand(host: String, connectTimeout: Int = 5, controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        // the far side runs the BARE form of the same command, which does the whole join in one
        // main-actor walk of its own windows and answers with one document
        let chain = cliPathPrefix + " && agtermctl zmx tree --json"
        // sshd runs the remote command through the ACCOUNT's shell, where a bare `VAR=value` assignment is
        // a syntax error in fish and tcsh; wrapped, every login shell sees one ordinary command, as
        // `attachCommand` already sends.
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false, controlPath: controlPath) + [remote]
    }

    /// One ssh invocation creating an attachable session on `host` with the far side's host-less `zmx new`,
    /// which answers with the new session's id. Each value travels as one `--flag=value` word, so a value
    /// starting with `-` stays a value.
    public static func newCommand(host: String, options: ControlZmxNewOptions, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        let flags = [("name", options.name), ("command", options.command), ("cwd", options.cwd)]
            // `--flag=` with nothing after it is a missing value to the far side's parser, not an empty one
            .compactMap { flag, value in value.flatMap { $0.isEmpty ? nil : "--\(flag)=\($0)" } }
        let chain = cliPathPrefix + " && agtermctl " + CommandRestore.shellQuotedLine(["zmx", "new", "--json"] + flags)
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false) + [remote]
    }

    /// One ssh invocation carrying `session`'s presentation stream, for as long as the row is shown.
    ///
    /// `-T` because frames travel on plain stdio and a pty would mangle them, and no lifetime deadline:
    /// the stream is meant to stay up. `exec` so the far-side shell does not linger between ssh and the
    /// bridge, which would keep a dead bridge's stdio open.
    public static func presentCommand(host: String, session: String, connectTimeout: Int = 5, controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        guard isPlain(session) else { throw InvocationError.invalidSession }
        let chain = cliPathPrefix + " && exec agtermctl zmx present " + CommandRestore.shellQuotedLine([session])
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        // a pooled row rides its leased master; any other stream opens a connection of its own
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false, controlPath: controlPath,
                            options: controlPath == nil ? ownConnection : []) + [remote]
    }

    /// catalogCommand carries agterm-server's catalog stream for a remote window, for as long as it is open; plain
    /// stdio and `exec` for the reasons `presentCommand` gives.
    public static func catalogCommand(host: String, connectTimeout: Int = 5, controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        let chain = cliPathPrefix + " && exec agtermctl catalog subscribe"
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false, controlPath: controlPath) + [remote]
    }

    /// endedCommand is what a catalog row whose session ended shows in place of an attach: a line naming the host,
    /// held open, so a row this Mac has no screen for never starts a local shell.
    public static func endedCommand(host: String) -> String {
        let line = "printf '\\033[2mEnded on %s\\033[0m\\n' " + CommandRestore.shellQuotedLine([TerminalText.sanitized(host)])
        return CommandRestore.shellQuotedLine(["/bin/sh", "-c", line + "; exec cat >/dev/null"])
    }

    /// One ssh invocation running the helper for `job`, an overlay the origin handed to this Mac, for as long
    /// as the overlay is up. `-tt` because the program is the user's and reads the pty; `exec` so the helper's
    /// hangup check sees the ssh session's own pty close.
    public static func runJobCommand(host: String, job: String, token: String? = nil, connectTimeout: Int = 5,
                                     controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        guard isPlain(job), token.map(isPlain) ?? true else { throw InvocationError.invalidSession }
        let chain = cliPathPrefix + " && exec agtermctl session overlay run-job "
            + CommandRestore.shellQuotedLine([job] + (token.map { ["--token", $0] } ?? []))
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        // one channel per job unless the pool leases it one: an unleased shared connection was measured refusing
        // channels (`Session open refused by peer`)
        let options = controlPath == nil ? ownConnection : []
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: true, controlPath: controlPath,
                            options: options) + [remote]
    }

    /// pageServeCommand uses plain ssh stdio to claim and carry a remote page's channel.
    public static func pageServeCommand(host: String, token: String, connectTimeout: Int = 5, controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        guard isPlain(token) else { throw InvocationError.invalidSession }
        let chain = cliPathPrefix + " && exec agtermctl session overlay page-serve " + CommandRestore.shellQuotedLine([token])
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false, controlPath: controlPath) + [remote]
    }

    /// pasteReceiveCommand runs the far side's `agtermctl paste receive`, which reads a paste bundle on plain ssh stdin.
    public static func pasteReceiveCommand(host: String, connectTimeout: Int = 5, controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        let chain = cliPathPrefix + " && exec agtermctl paste receive"
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false, controlPath: controlPath) + [remote]
    }

    /// forwardCommand is a forward of its own for a row with no pooled master: ControlMaster and ControlPath are
    /// switched off over any ssh_config, so the listener lives in this process and ends with it. It takes the pane
    /// attach's keepalive, or a half-open link would leave it running with the page's port dead.
    public static func forwardCommand(host: String, spec: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        let options = ["-T", "-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-o", "ControlMaster=no",
                       "-o", "ControlPath=none", "-o", "ExitOnForwardFailure=yes"]
        let ssh = CommandRestore.shellQuotedLine(["ssh"] + options) + " $ka " + CommandRestore.shellQuotedLine(["-L", spec, host])
        return ["/bin/sh", "-c", keepAliveCheck(options + [host]) + "; exec " + ssh]
    }

    /// forwardControlCommand adds (`forward`), removes (`cancel`) or, with no spec, checks the master at `controlPath`.
    public static func forwardControlCommand(_ operation: String, host: String, controlPath: String, spec: String? = nil) throws -> [String] {
        try validate(host: host)
        return ["ssh", "-O", operation, "-o", "ControlPath=" + controlPath] + (spec.map { ["-L", $0] } ?? []) + [host]
    }

    /// connectionPID reads the pid `ssh -O check` reports for a running master, nil when it reports none.
    public static func connectionPID(_ output: String) -> Int32? {
        guard let start = output.range(of: "(pid=")?.upperBound, let end = output[start...].firstIndex(of: ")") else { return nil }
        return Int32(output[start..<end])
    }

    /// optionArgument joins a value to its flag, since ArgumentParser reads a following word starting with `-` as an
    /// option, but keeps an empty one as its own word, since it reads a bare `--flag=` as a missing value.
    public static func optionArgument(_ flag: String, _ value: String?) -> [String] {
        guard let value else { return [] }
        return value.isEmpty ? [flag, value] : [flag + "=" + value]
    }

    /// One ssh invocation running the far side's `agtermctl` with `arguments` plus `--json`, so the reply is the
    /// server's own response line. Arguments carry user text, so the outer layer is quoted for any login shell.
    /// `operands` follow a `--`, so one starting with `-` is never read as an option.
    public static func controlCommand(host: String, arguments: [String], operands: [String] = [], connectTimeout: Int = 5,
                                      controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        let tail = operands.isEmpty ? [] : ["--"] + operands
        let chain = cliPathPrefix + " && agtermctl " + CommandRestore.shellQuotedLine(arguments + ["--json"] + tail)
        let remote = ["/bin/sh", "-c", chain].map(CommandRestore.accountShellQuoted).joined(separator: " ")
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false, controlPath: controlPath) + [remote]
    }

    /// sshd's PATH and a profile-less shell miss an installed CLI (exit 127), so `CommandPath`'s Mac directories and
    /// agterm-server's `$HOME/.local/bin` are APPENDED: a user's own `agtermctl` earlier on PATH still wins.
    static var cliPathPrefix: String {
        "PATH=\"$PATH:" + (CommandPath.standardDirectories + ["$HOME/.local/bin"]).joined(separator: ":") + "\""
    }

    /// One ssh invocation attaching to `daemon` on `host`, for the lifetime of the pane.
    ///
    /// `-tt` forces a pty: a remote command does not reliably get one, and zmx reads termios and the
    /// window size. There is no lifetime deadline — this is meant to stay connected.
    ///
    /// The trailing `/bin/sh -c` is a create-only guard, not a command we expect to run. Stock
    /// `zmx attach` CREATES the daemon when the name is absent, so a daemon that vanished since the tree
    /// was read would otherwise hand the user a fresh remote shell wearing the old session's name. An
    /// existing daemon ignores the command; a vanished one runs this and fails, saying so.
    ///
    /// `env` and `sh` are spelled absolutely because they are implementation primitives. The remote
    /// `agtermctl` in `treeCommand` is deliberately PATH-resolved instead — that one IS the user's
    /// installed CLI.
    ///
    /// Under mosh the remote argv travels VERBATIM after `--`: mosh quotes each element itself, the far
    /// login shell unquotes them back into separate arguments and mosh-server `execvp`s them with no
    /// shell in between. The ssh form's one pre-quoted line would reach that `execvp` as a single bogus
    /// program name. `--server=` is interpolated into the far side's shell line raw, so the path is held
    /// to `isPlainMoshServer` rather than escaped. The LOCAL `mosh` is resolved off `moshCandidates`
    /// rather than left bare, because libghostty spawns the pane with the GUI launch PATH; `moshCandidates`
    /// and `fileExists` are injectable so a test drives the probe without touching the real filesystem.
    ///
    /// `lead` opts the far zmx client into explicit leadership; an origin whose zmx predates it ignores
    /// the two variables and the pane behaves as it did before.
    public static func attachCommand(host: String, endpoint: ControlZmxEndpoint, daemon: String,
                                     lead: ZmxLeadAttachment? = nil,
                                     connectTimeout: Int = 5, controlPath: String? = nil,
                                     transport: RemoteTransport = .ssh,
                                     moshCandidates: [String] = RemoteSession.moshClientCandidates,
                                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws -> [String] {
        try validate(host: host)
        guard ZmxSupport.isDaemonName(daemon) || ZmxSupport.isScratchDaemonName(daemon) else { throw InvocationError.invalidSession }
        guard isPath(endpoint.executable), isPath(endpoint.socketDirectory) else {
            throw InvocationError.invalidEndpoint
        }
        let guardScript = "printf '%s\\n' 'agterm: remote session is gone'; exit 1"
        let remoteArgv = [
            // the four the LOCAL pane sets in `ZmxSupport`, empty being unset to zmx: an inherited
            // `ZMX_SESSION` makes attach SWITCH session instead, never reaching the create-only guard,
            // and an inherited prefix resolves a name agterm never created.
            "/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_NO_DETACH_KEY=1",
            "ZMX_DIR=" + endpoint.socketDirectory,
        ] + (lead?.assignments ?? []) + [
            endpoint.executable, "attach", daemon, "/bin/sh", "-c", guardScript,
        ]
        // a control path is a pooled ssh master, which a mosh link cannot ride
        let prefix = try controlPath.map { path in
            guard case .ssh = transport else { throw InvocationError.invalidTransport }
            return sshArguments(host: host, connectTimeout: connectTimeout, interactive: true, controlPath: path)
        } ?? transportArguments(host: host, transport: transport, connectTimeout: connectTimeout,
                                moshCandidates: moshCandidates, fileExists: fileExists)
        switch transport {
        case .ssh:
            // why ERROR: control-api.md, Remote sessions
            var argv = prefix + [CommandRestore.shellQuotedLine(remoteArgv)]
            argv.insert(contentsOf: ["-o", "LogLevel=ERROR"], at: argv.count - 2)
            return argv
        case .mosh:
            return prefix + remoteArgv
        }
    }

    /// screenCommand reads `daemon`'s screen on `host` through the origin's own zmx, which every origin kind ships;
    /// `agtermctl zmx screen` would not do, as agterm-headless refuses it. A short call, so it keeps the user's ssh
    /// config and takes no pooled master.
    public static func screenCommand(host: String, endpoint: ControlZmxEndpoint, daemon: String, all: Bool,
                                     connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        guard ZmxSupport.isDaemonName(daemon) else { throw InvocationError.invalidSession }
        guard isPath(endpoint.executable), isPath(endpoint.socketDirectory) else { throw InvocationError.invalidEndpoint }
        // the variables `attachCommand` clears, for the same reason: an inherited one renames the daemon
        let remote = ["/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_DIR=" + endpoint.socketDirectory,
                      endpoint.executable, "screen", daemon] + (all ? ["--all"] : [])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false) + [CommandRestore.shellQuotedLine(remote)]
    }

    /// keepAliveCheck is shell that sets `$ka` to the ServerAlive options when `ssh -G` with `arguments` reports
    /// none configured, and to nothing otherwise. When and why: control-api.md, Remote sessions.
    static func keepAliveCheck(_ arguments: [String]) -> String {
        "ka=; " + CommandRestore.shellQuotedLine(["ssh", "-G"] + arguments)
            + " 2>/dev/null | grep -qx 'serveraliveinterval 0'"
            + " && ka='-o ServerAliveInterval=5 -o ServerAliveCountMax=2'"
    }

    /// attachPaneCommand is the pane's command: the attach, then `paneModeReset`, exiting with SSH's status. It prints no notice: the
    /// app draws one over the kept remote screen. `session` and `pane` are kept for the agterm-linux fork's callers.
    ///
    /// On ssh's own failure, 255, an attach with a lead or `linkNonce` reports that under `RemoteLinkNotice` and waits
    /// on `cat` for the app to attach the pane again; `cat` ends with the app's pty. Echo goes off with the cursor, as
    /// Ghostty draws its password lock in place of the cursor while echo is off.
    ///
    /// Under mosh `$status` is mosh-client's exit status, not the guard's `exit 1`, so a vanished daemon reads as exit 0.
    public static func attachPaneCommand(host: String, endpoint: ControlZmxEndpoint, daemon: String,
                                         session: String, pane: ZmxPaneRole,
                                         lead: ZmxLeadAttachment? = nil, linkNonce: String? = nil,
                                         connectTimeout: Int = 5, controlPath: String? = nil,
                                         transport: RemoteTransport = .ssh,
                                         moshCandidates: [String] = RemoteSession.moshClientCandidates,
                                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws -> String {
        let argv = try attachCommand(host: host, endpoint: endpoint, daemon: daemon, lead: lead,
                                     connectTimeout: connectTimeout, controlPath: controlPath, transport: transport,
                                     moshCandidates: moshCandidates, fileExists: fileExists)
        let keepAlive: String
        let attach: String
        switch transport {
        case .ssh:
            // $ka is unquoted on purpose: four words or none. When and why the check: control-api.md, Remote sessions
            keepAlive = keepAliveCheck(Array(argv.dropFirst())) + "; "
            attach = CommandRestore.shellQuotedLine(Array(argv.dropLast(2))) + " $ka "
                + CommandRestore.shellQuotedLine(Array(argv.suffix(2)))
        case .mosh:
            // the keepalive is ssh's: `ssh -G` cannot read a mosh argv, and mosh keeps its own link alive
            keepAlive = ""
            attach = CommandRestore.shellQuotedLine(argv)
        }
        // a pooled pane waits for its master; one that never came up is a lost connection, so 255
        let run = controlPath == nil ? "\(attach); status=$?"
            : "if agterm_connection_wait; then \(attach); status=$?; else status=255; fi"
        let prelude = controlPath.map { connectionWait(host: host, controlPath: $0) + "; " } ?? ""
        var wait = ""
        if let nonce = lead?.nonce ?? linkNonce {
            let title = CommandRestore.shellQuotedLine([RemoteLinkNotice.title(nonce: nonce)])
            wait = "if [ \"$status\" -eq 255 ]; then printf '\\033]2;%s\\007' \(title); printf '\\033[?25l'; "
                + "stty -echo 2>/dev/null; cat >/dev/null; fi; "
        }
        // the pane must exit with SSH's status, not printf's zero, or a failed connection reads as a clean one
        let script = "\(prelude)\(keepAlive)\(run); printf '\(paneModeReset)'; \(wait)exit \"$status\""
        // libghostty runs this as `exec -l <command>`: bare, the exec replaces the shell with ssh and nothing
        // after it runs. `env` takes the exec instead, and a plain `sh` beneath it reads no login profile.
        return CommandRestore.shellQuotedLine(["/usr/bin/env", "/bin/sh", "-c", script])
    }

    /// Where a Homebrew or manual `mosh` installs, in probe order. The pane's command runs under
    /// libghostty's GUI launch PATH, which has no `/opt/homebrew/bin`, so a bare `mosh` exits 127 on an
    /// Apple-Silicon Homebrew install. `--mosh PATH` overrides the lookup for anywhere else.
    public static let moshClientCandidates = ["/opt/homebrew/bin/mosh", "/usr/local/bin/mosh", "/usr/bin/mosh"]

    /// The transport's own arguments, through the separator that ends them: ssh takes the remote line
    /// as one last quoted element, mosh takes the argv verbatim after `--`.
    private static func transportArguments(host: String, transport: RemoteTransport,
                                           connectTimeout: Int, moshCandidates: [String],
                                           fileExists: (String) -> Bool) throws -> [String] {
        switch transport {
        case .ssh:
            return sshArguments(host: host, connectTimeout: connectTimeout, interactive: true, options: ownConnection)
        case .mosh(let server, let client):
            // mosh splits its `--ssh=` value with shellwords, so the two options reach ssh as separate
            // options. Required on a Mac far side: mosh's bootstrap is a non-login shell, where a
            // Homebrew mosh-server is otherwise off PATH.
            let bootstrap = "--ssh=ssh -o BatchMode=yes -o ConnectTimeout=\(connectTimeout)"
            if let server, !isPlainMoshServer(server) { throw InvocationError.invalidTransport }
            if let client, !isPlainMoshServer(client) { throw InvocationError.invalidTransport }
            let mosh = client ?? moshCandidates.first(where: fileExists) ?? "mosh"
            guard let server else { return [mosh, bootstrap, host, "--"] }
            return [mosh, "--server=" + server, bootstrap, host, "--"]
        }
    }

    /// paneModeReset is what the wrapper prints once the attach ends: a remote program's mouse and focus reports would
    /// echo onto the kept screen, and its kitty flags (`=0u`) let a bare modifier close a held pane.
    static let paneModeReset = "\\033[0m\\033[?1000l\\033[?1002l\\033[?1003l\\033[?1006l\\033[?1004l\\033[?2004l"
        + "\\033[?2031l\\033[?2048l\\033[=0u"

    /// One ssh invocation that only proves the host answers again, before a waiting pane is attached anew.
    /// Without a pooled master it opens its own connection: through the user's shared master it would prove that
    /// the master answers, not the host.
    public static func probeCommand(host: String, controlPath: String? = nil) throws -> [String] {
        try validate(host: host)
        return sshArguments(host: host, connectTimeout: 5, interactive: false, controlPath: controlPath,
                            options: controlPath == nil ? ownConnection : []) + ["true"]
    }

    /// connectionWait defines `agterm_connection_wait`, for a command libghostty launches and the app cannot hold back
    /// until the pool has the master up: it polls the master for 15 s and returns 255, ssh's own failure, when
    /// none came up, so the caller fails into its reconnect path rather than opening a connection of its own.
    static func connectionWait(host: String, controlPath: String) -> String {
        let check = CommandRestore.shellQuotedLine(["ssh", "-O", "check", "-o", "ControlPath=" + controlPath, host])
        return "agterm_connection_wait() { i=0; while ! \(check) 2>/dev/null; do i=$((i+1)); "
            + "[ \"$i\" -ge 75 ] && return 255; sleep 0.2; done; }"
    }

    /// waitingForConnection runs `line`, a job helper's command, once its master answers; without one it says so and
    /// exits 255.
    public static func waitingForConnection(_ line: String, host: String, controlPath: String) -> String {
        let failed = CommandRestore.shellQuotedLine(["agterm: no connection to \(host)"])
        let script = connectionWait(host: host, controlPath: controlPath)
            + "; agterm_connection_wait || { printf '%s\\n' \(failed); exit 255; }; exec " + line
        return CommandRestore.shellQuotedLine(["/usr/bin/env", "/bin/sh", "-c", script])
    }

    /// Opts one invocation out of the user's `ControlMaster` multiplexing. Every link that stays up and has no
    /// pooled master takes it: a pane, a presentation stream and an overlay job each hold a channel for hours,
    /// and sshd caps the channels of one connection (`MaxSessions`, 10 by default), so a shared master was
    /// measured refusing them (`Session open refused by peer`). A channel on a master also never sees ssh exit
    /// 255: when the link dies the master stays open unless its own settings carry a keepalive, and every pane
    /// on it freezes with no reconnect. The probe takes it for the same reason. Short calls keep the shared
    /// connection, which is what the user configured it for.
    static let ownConnection = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    private static func sshArguments(host: String, connectTimeout: Int, interactive: Bool, controlPath: String? = nil,
                                     options: [String] = []) -> [String] {
        var argv = ["ssh", interactive ? "-tt" : "-T",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=\(connectTimeout)"]
        if let controlPath {
            argv += ["-o", "ControlMaster=auto", "-o", "ControlPath=" + controlPath, "-o", "ControlPersist=60"]
        }
        return argv + options + [host]
    }

    /// Refused rather than escaped, and a leading `-` with it: ssh would read that as an option.
    private static func validate(host: String) throws {
        guard !host.isEmpty else { throw InvocationError.emptyHost }
        guard isHost(host) else { throw InvocationError.invalidHost }
    }

    /// isHost reports whether `value` may be handed to ssh as its destination argument.
    static func isHost(_ value: String) -> Bool {
        isPlain(value) && !value.hasPrefix("-")
    }

    /// A host or remote-session token: no whitespace, no control characters. Shared with the dispatcher,
    /// so one predicate decides what may reach both an argv and an error message.
    static func isPlain(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// A `--mosh-server` path, which `isPlain` is too weak for: mosh interpolates `--server=<value>` raw
    /// into the far side's login-shell line, where `;`, quotes, `$`, backticks and `~` would act. REFUSED
    /// rather than escaped, so the set is closed and a legal path carrying an odd character fails loudly
    /// instead of arriving mangled on the far side.
    static func isPlainMoshServer(_ value: String) -> Bool {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/@:+=%,-"
        return !value.isEmpty && value.allSatisfy { allowed.contains($0) }
    }

    /// A filesystem path, which may legitimately contain spaces — `/Users/me/My Apps/agterm.app/…` is an
    /// ordinary install. `shellQuotedLine` keeps it one argument through the remote shell, so only
    /// control characters and NUL are refused, neither of which survives a path anyway.
    private static func isPath(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
