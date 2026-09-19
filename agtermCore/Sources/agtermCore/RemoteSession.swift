import Foundation

/// How an attach reaches the far side. ssh is the default and the pre-existing behavior; mosh survives
/// roaming and laptop sleep, at the cost of a different argv shape (see `RemoteSession.attachCommand`).
public enum RemoteTransport: Equatable, Sendable {
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
    public static func treeCommand(host: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        // the far side runs the BARE form of the same command, which does the whole join in one
        // main-actor walk of its own windows and answers with one document
        let chain = cliPathPrefix + " && agtermctl zmx tree --json"
        // sshd runs the remote command through the ACCOUNT's shell, where a bare `VAR=value` assignment is
        // a syntax error in fish and tcsh; wrapped, every login shell sees one ordinary command, as
        // `attachCommand` already sends.
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false) + [remote]
    }

    /// One ssh invocation carrying `session`'s presentation stream, for as long as the row is shown.
    ///
    /// `-T` because frames travel on plain stdio and a pty would mangle them, and no lifetime deadline:
    /// the stream is meant to stay up. `exec` so the far-side shell does not linger between ssh and the
    /// bridge, which would keep a dead bridge's stdio open.
    public static func presentCommand(host: String, session: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        guard isPlain(session) else { throw InvocationError.invalidSession }
        let chain = cliPathPrefix + " && exec agtermctl zmx present " + CommandRestore.shellQuotedLine([session])
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false) + [remote]
    }

    /// sshd runs a remote command with `/usr/bin:/bin:/usr/sbin:/sbin` and a non-interactive shell reads no
    /// profile, so an installed CLI is otherwise not found and every command exits 127. `CommandPath` owns
    /// where it can live; APPENDED, so a user's own `agtermctl` earlier on PATH still wins.
    static var cliPathPrefix: String {
        "PATH=\"$PATH:" + CommandPath.standardDirectories.joined(separator: ":") + "\""
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
    public static func attachCommand(host: String, endpoint: ControlZmxEndpoint, daemon: String,
                                     connectTimeout: Int = 5,
                                     transport: RemoteTransport = .ssh,
                                     moshCandidates: [String] = RemoteSession.moshClientCandidates,
                                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws -> [String] {
        try validate(host: host)
        guard ZmxSupport.isDaemonName(daemon) else { throw InvocationError.invalidSession }
        guard isPath(endpoint.executable), isPath(endpoint.socketDirectory) else {
            throw InvocationError.invalidEndpoint
        }
        let guardScript = "printf '%s\\n' 'agterm: remote session is gone'; exit 1"
        let remoteArgv = [
            // the four the LOCAL pane sets in `ZmxSupport`, empty being unset to zmx: an inherited
            // `ZMX_SESSION` makes attach SWITCH session instead, never reaching the create-only guard,
            // and an inherited prefix resolves a name agterm never created.
            "/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_NO_DETACH_KEY=1",
            "ZMX_DIR=" + endpoint.socketDirectory, endpoint.executable,
            "attach", daemon, "/bin/sh", "-c", guardScript,
        ]
        let prefix = try transportArguments(host: host, transport: transport, connectTimeout: connectTimeout,
                                            moshCandidates: moshCandidates, fileExists: fileExists)
        switch transport {
        case .ssh:
            return prefix + [CommandRestore.shellQuotedLine(remoteArgv)]
        case .mosh:
            return prefix + remoteArgv
        }
    }

    /// The pane's command: the attach, then one line saying what died. `commandWait` holds the pane on
    /// Ghostty's own press-any-key prompt, so this sits under the last remote screen until it is read.
    ///
    /// It names the host, the session and the exit status and stops there. How to get back is not
    /// agterm's to say: the picker is a keymap custom command the user supplies.
    ///
    /// Under mosh the tail's `status=$?` is mosh-client's exit status, not the guard's `exit 1`, so
    /// `disconnected, exit 0` after a vanished daemon is expected there.
    public static func attachPaneCommand(host: String, endpoint: ControlZmxEndpoint, daemon: String,
                                         session: String, pane: ZmxPaneRole,
                                         connectTimeout: Int = 5,
                                         transport: RemoteTransport = .ssh,
                                         moshCandidates: [String] = RemoteSession.moshClientCandidates,
                                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws -> String {
        let attach = CommandRestore.shellQuotedLine(
            try attachCommand(host: host, endpoint: endpoint, daemon: daemon,
                              connectTimeout: connectTimeout, transport: transport,
                              moshCandidates: moshCandidates, fileExists: fileExists))
        let label = CommandRestore.shellQuotedLine(
            ["agterm: \(session) (\(pane.rawValue)) on \(host) disconnected, exit"])
        // the pane must exit with SSH's status, not printf's zero, or a failed connection reads as a
        // clean one to anything that looks at the exit code
        return "\(attach); status=$?; printf '%s %s\\n' \(label) \"$status\"; exit \"$status\""
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
            return sshArguments(host: host, connectTimeout: connectTimeout, interactive: true)
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

    private static func sshArguments(host: String, connectTimeout: Int, interactive: Bool) -> [String] {
        ["ssh", interactive ? "-tt" : "-T",
         "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=\(connectTimeout)",
         host]
    }

    /// Refused rather than escaped, and a leading `-` with it: ssh would read that as an option.
    private static func validate(host: String) throws {
        guard !host.isEmpty else { throw InvocationError.emptyHost }
        guard isPlain(host), !host.hasPrefix("-") else { throw InvocationError.invalidHost }
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
