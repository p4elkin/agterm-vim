import ArgumentParser
#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

/// The ssh leg of the two-phase overlay redirect. Serialized: the escaping tests set process-global
/// environment variables to point the generated command lines at fake `agtermctl`/`ssh` programs.
@Suite(.serialized)
struct OverlayRedirectSshTests {
    // MARK: - the desk path

    // The everyday case, and the one this whole feature must not disturb: nobody is watching remotely, so
    // the CLI sends exactly the request it sent before this feature existed and stops there.
    @Test func aLocalOutcomeSendsTodaysRequestAndNothingElse() throws {
        let effects = Effects()
        effects.responses = [ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["revdiff", "--cwd", "/b", "--target", "9f3c"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests == [try open.makeRequest()])
        #expect(effects.ssh.isEmpty)
        #expect(effects.scripts.isEmpty)
    }

    @Test func aLocalOutcomeWithBlockPollsHereAndSpawnsNoSsh() throws {
        let effects = Effects()
        effects.responses = [ControlResponse(ok: true, result: ControlResult(id: "9f3c")),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c", exitCode: 7))]
        let open = try Session.Overlay.Open.parse(["revdiff", "--block"])

        #expect(throws: ExitCode(rawValue: 7)) {
            try open.runRedirecting(environment: effects.environment, send: effects.send)
        }
        #expect(effects.requests.map(\.cmd) == [.sessionOverlayOpen, .sessionOverlayResult])
        #expect(effects.ssh.isEmpty)
    }

    @Test func aFailedOpenStillFailsWithoutRedirecting() throws {
        let effects = Effects()
        effects.responses = [ControlResponse(ok: false, error: "no such session")]
        let open = try Session.Overlay.Open.parse(["revdiff"])

        #expect(throws: ExitCode.failure) {
            try open.runRedirecting(environment: effects.environment, send: effects.send)
        }
        #expect(effects.ssh.isEmpty)
    }

    // MARK: - mirror-of: open here, run there

    @Test func mirrorOfOpensHereWithTheProgramWrappedInSshToTheSourceHost() throws {
        let effects = Effects()
        effects.responses = [redirected(.init(outcome: .mirrorOf, host: "p4studio.local"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["lazygit", "--follow"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.count == 2)
        let resend = try #require(effects.requests.last)
        #expect(resend.cmd == .sessionOverlayOpen)
        #expect(resend.target == "9f3c")
        #expect(resend.args?.resolved == true)
        #expect(resend.args?.follow == true)
        #expect(resend.args?.command
            == #"ssh -o ConnectTimeout=2 -t 'p4studio.local' 'cd "/w/repo" && lazygit'"#)
        #expect(effects.ssh.isEmpty)
    }

    // ⚠️ The regression this pins: none of the nine keymap chords passes --cwd, and a mirrored row's PWD is
    // already a path on the workstation (its shell IS the remote shell, over mosh). Dropping it started
    // lazygit in the far side's $HOME instead of the repository the row is sitting in.
    @Test func mirrorOfCdsOnTheFarSideWithTheProcessDirectoryWhenNoCwdWasPassed() throws {
        let effects = Effects()
        effects.currentDirectory = "/w/$repo"
        effects.responses = [redirected(.init(outcome: .mirrorOf, host: "studio"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["lazygit"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.last?.args?.command
            == #"ssh -o ConnectTimeout=2 -t 'studio' 'cd "/w/\$repo" && lazygit'"#)
        #expect(effects.requests.last?.args?.cwd == nil)
    }

    // ⚠️ The real fix. A mirrored row's process directory is ALWAYS `$HOME`: libghostty drops the remote
    // shell's OSC 7 as not local, so the row falls back to the `--cwd "$HOME"` the mirror job pinned at
    // creation. `/Users/sasha` exists on both machines, so the `cd` succeeded and lazygit opened in the
    // workstation's home instead of the repository. The pairing carries the real directory instead.
    @Test func mirrorOfPrefersThePairingCwdOverTheProcessDirectory() throws {
        let effects = Effects()
        effects.currentDirectory = "/Users/sasha"
        effects.responses = [redirected(.init(outcome: .mirrorOf, host: "studio", cwd: "/w/agterm"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["lazygit"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.last?.args?.command
            == #"ssh -o ConnectTimeout=2 -t 'studio' 'cd "/w/agterm" && lazygit'"#)
    }

    // An explicit --cwd names the path the caller means, and wins over the pairing's own.
    @Test func mirrorOfPrefersAnExplicitCwdOverThePairingCwd() throws {
        let effects = Effects()
        effects.currentDirectory = "/Users/sasha"
        effects.responses = [redirected(.init(outcome: .mirrorOf, host: "studio", cwd: "/w/agterm"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["lazygit", "--cwd", "/w/chosen"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.last?.args?.command
            == #"ssh -o ConnectTimeout=2 -t 'studio' 'cd "/w/chosen" && lazygit'"#)
    }

    // An explicit --cwd names the path the caller means, and wins over the process directory.
    @Test func mirrorOfPrefersAnExplicitCwdOverTheProcessDirectory() throws {
        let effects = Effects()
        effects.currentDirectory = "/ignored"
        effects.responses = [redirected(.init(outcome: .mirrorOf, host: "studio"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["lazygit", "--cwd", "/w/chosen"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.last?.args?.command
            == #"ssh -o ConnectTimeout=2 -t 'studio' 'cd "/w/chosen" && lazygit'"#)
    }

    // --block travels through the mirror-of arm untouched: the overlay is LOCAL there, so the existing
    // poll loop runs and returns the wrapped ssh's status, with no ssh spawned by agtermctl itself.
    @Test func mirrorOfWithBlockStillPollsTheLocalOverlay() throws {
        let effects = Effects()
        effects.responses = [redirected(.init(outcome: .mirrorOf, host: "studio"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c")),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c", exitCode: 4))]
        let open = try Session.Overlay.Open.parse(["lazygit", "--block"])

        #expect(throws: ExitCode(rawValue: 4)) {
            try open.runRedirecting(environment: effects.environment, send: effects.send)
        }
        #expect(effects.requests.map(\.cmd) == [.sessionOverlayOpen, .sessionOverlayOpen, .sessionOverlayResult])
        #expect(effects.ssh.isEmpty)
    }

    // MARK: - `pairing mirrors --cwd`, what the mirror job sends every pass

    @Test func pairingMirrorsSendsTheCwdItWasGiven() throws {
        let request = try Pairing.Mirrors.parse(["--host", "studio", "--session", "s1",
                                                 "--cwd", "/w/agterm"]).makeRequest()
        #expect(request.cmd == .sessionPairing)
        #expect(request.args?.mode == "mirrors")
        #expect(request.args?.host == "studio")
        #expect(request.args?.cwd == "/w/agterm")
    }

    // An older mirror job sends no `--cwd`, and its pairing must still be accepted: the CLI then falls back
    // to the process directory, exactly as it did before this option existed.
    @Test func pairingMirrorsWithoutACwdSendsNone() throws {
        let request = try Pairing.Mirrors.parse(["--host", "studio", "--session", "s1"]).makeRequest()
        #expect(request.args?.cwd == nil)
    }

    @Test func pairingMirrorsClearSendsNoCwd() throws {
        #expect(try Pairing.Mirrors.parse(["--clear"]).makeRequest().args?.cwd == nil)
    }

    @Test func pairingMirrorsRejectsACwdAlongsideClear() {
        #expect(throws: (any Error).self) {
            _ = try Pairing.Mirrors.parse(["--clear", "--cwd", "/w/agterm"])
        }
    }

    // MARK: - watched-by: send the open there, run back here

    @Test func watchedBySendsTheOpenToTheViewerAndOpensNothingHere() throws {
        let effects = Effects()
        effects.responses = [redirected(.init(outcome: .watchedBy, host: "air", row: "7b21"), id: "9f3c")]
        let open = try Session.Overlay.Open.parse(["revdiff", "--cwd", "/b"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.count == 1)
        #expect(effects.scripts.map(\.cwd) == ["/b"])
        #expect(effects.scripts.map(\.command) == ["revdiff"])
        let argv = try #require(effects.ssh.first)
        #expect(argv.count == 6)
        #expect(Array(argv.prefix(5)) == ["-n", "-o", "ConnectTimeout=2", "--", "air"])
        #expect(argv[5].contains("--target '7b21'"))
        #expect(effects.ssh.count == 1)
    }

    // --block is carried, never reimplemented: the remote agtermctl blocks and its status returns through
    // ssh. The local poll loop must not run — it would poll a local session that has no overlay.
    @Test func watchedByPassesBlockToTheRemoteAgtermctlAndNeverPollsHere() throws {
        let effects = Effects()
        effects.sshStatus = 3
        effects.responses = [redirected(.init(outcome: .watchedBy, host: "air", row: "7b21"), id: "9f3c")]
        let open = try Session.Overlay.Open.parse(["revdiff", "--block"])

        #expect(throws: ExitCode(rawValue: 3)) {
            try open.runRedirecting(environment: effects.environment, send: effects.send)
        }
        #expect(effects.requests.map(\.cmd) == [.sessionOverlayOpen])
        #expect(try #require(effects.ssh.first).last?.contains(" --block") == true)
    }

    @Test func watchedBySuccessExitsQuietlyWithoutASecondRequest() throws {
        let effects = Effects()
        effects.responses = [redirected(.init(outcome: .watchedBy, host: "air", row: "7b21"), id: "9f3c")]
        let open = try Session.Overlay.Open.parse(["revdiff"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.count == 1)
    }

    // ssh reserves 255 for its own failures. The far side being asleep must land on a plain local overlay
    // running the caller's OWN command, not the ssh-back wrapper — and must clear the pairing that just
    // failed, so the pill goes grey instead of claiming the overlay went to a machine it never reached.
    @Test func anUnreachableViewerClearsThePairingAndFallsBackToAPlainLocalOverlay() throws {
        let effects = Effects()
        effects.sshStatus = 255
        effects.responses = [redirected(.init(outcome: .watchedBy, host: "air", row: "7b21"), id: "9f3c"),
                             ControlResponse(ok: true),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["revdiff", "--cwd", "/b"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.map(\.cmd)
            == [.sessionOverlayOpen, .sessionPairing, .sessionOverlayOpen])
        let cleared = effects.requests[1]
        #expect(cleared.target == "9f3c")
        #expect(cleared.args?.mode == "viewer")
        #expect(cleared.args?.host == "")
        let fallback = try #require(effects.requests.last)
        #expect(fallback.args?.resolved == true)
        #expect(fallback.args?.command == "revdiff")
        #expect(fallback.args?.cwd == "/b")
        #expect(fallback.target == "9f3c")
        #expect(effects.removed == ["/tmp/agterm-overlay-redirect-1/42.sh"],
                "a script the viewer never ran must not be left behind")
    }

    // Without --block the remote agtermctl returns as soon as the OPEN is done, so any nonzero status there
    // is a failed open (an older agtermctl over there, the row gone inside the staleness window, --pane on an
    // unsplit row) — the overlay still has to appear somewhere.
    @Test func aRefusedRemoteOpenFallsBackLocallyWhenNotBlocking() throws {
        let effects = Effects()
        effects.sshStatus = 1
        effects.responses = [redirected(.init(outcome: .watchedBy, host: "air", row: "7b21"), id: "9f3c"),
                             ControlResponse(ok: true),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["revdiff"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.requests.last?.args?.resolved == true)
        #expect(effects.requests.last?.args?.command == "revdiff")
    }

    @Test func noSourceHostToSshBackToFallsBackToAPlainLocalOverlay() throws {
        let effects = Effects()
        effects.sourceHost = nil
        effects.responses = [redirected(.init(outcome: .watchedBy, host: "air", row: "7b21"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["revdiff"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.ssh.isEmpty)
        #expect(effects.requests.last?.args?.resolved == true)
        #expect(effects.requests.last?.args?.command == "revdiff")
    }

    @Test func anUnwritableSshBackScriptFallsBackToAPlainLocalOverlay() throws {
        let effects = Effects()
        effects.scriptPath = nil
        effects.responses = [redirected(.init(outcome: .watchedBy, host: "air", row: "7b21"), id: "9f3c"),
                             ControlResponse(ok: true, result: ControlResult(id: "9f3c"))]
        let open = try Session.Overlay.Open.parse(["revdiff"])

        try open.runRedirecting(environment: effects.environment, send: effects.send)

        #expect(effects.ssh.isEmpty)
        #expect(effects.requests.last?.args?.resolved == true)
    }

    // MARK: - the escaping chain

    @Test func doubleQuoteEscapingMatchesTheShellScriptItIsPortedFrom() {
        #expect(OverlayRedirectSsh.dqEscape(#"a\b"#) == #"a\\b"#)
        #expect(OverlayRedirectSsh.dqEscape(#"say "hi""#) == #"say \"hi\""#)
        #expect(OverlayRedirectSsh.dqEscape("cost $5") == #"cost \$5"#)
        #expect(OverlayRedirectSsh.dqEscape("`whoami`") == #"\`whoami\`"#)
        // the backslash pass runs first, so an already-escaped quote does not lose its own backslash
        #expect(OverlayRedirectSsh.dqEscape(#"\"$`"#) == #"\\\"\$\`"#)
    }

    @Test func singleQuotingSurvivesAnEmbeddedQuote() {
        #expect(OverlayRedirectSsh.sqQuote("plain") == "'plain'")
        #expect(OverlayRedirectSsh.sqQuote("it's") == #"'it'\''s'"#)
    }

    // The caller's command is stored in the script with no shell parse at write time, so it reaches its own
    // single evaluation intact. Self-deleting and exit-status-preserving, as its --block contract needs.
    @Test func theSshBackScriptIsWrittenByteForByte() {
        let command = #"revdiff --file "$HOME/a b" `x`"#
        let script = OverlayRedirectSsh.sourceScript(cwd: #"/w/$repo"#, command: command, directory: "/tmp/d")

        #expect(script == [
            "#!/bin/sh",
            #"cd "/w/\$repo" || { rm -rf -- "/tmp/d"; exit 1; }"#,
            command,
            "status=$?",
            #"rm -rf -- "/tmp/d""#,
            #"exit "$status""#,
            ""
        ].joined(separator: "\n"))
    }

    @Test func theWrittenScriptRunsTheCommandOnceThenCleansUpAndKeepsItsStatus() throws {
        let path = try OverlayRedirectSsh.writeSourceScript(
            cwd: NSTemporaryDirectory(), command: #"printf '%s\n' 'one $two "three"'; (exit 7)"#)
        let run = try shell("sh \(path)")

        #expect(run.status == 7)
        #expect(run.lines == [#"one $two "three""#])
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // One ssh hop and one `sh -c eval` sit between the string built here and the caller's command. Running
    // the real chain through /bin/sh with fake programs is the only proof that it survives both.
    @Test func theRemoteOpenCommandHandsAgtermctlTheTriggerAsOneArgument() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        setenv("AGTERM_REMOTE_AGTERMCTL", try fakeProgram(named: "agtermctl", in: dir), 1)
        defer { unsetenv("AGTERM_REMOTE_AGTERMCTL") }

        let open = try Session.Overlay.Open.parse([#"revdiff --file "a b""#, "--block", "--pane", "right"])
        let trigger = OverlayRedirectSsh.sshBackTrigger(sourceHost: "p4studio.local", scriptPath: "/tmp/d/1.sh")
        let run = try shell(open.remoteOpenCommand(trigger: trigger, row: "7b21"))

        #expect(run.lines == ["session", "overlay", "open", trigger,
                              "--target", "7b21", "--resolved", "--block", "--pane", "right"])
    }

    // ⚠️ The viewer's row is itself a mirrored row, so its own agterm would answer `mirror-of` and wrap the
    // trigger in a second ssh — straight back to the machine that sent it. `--resolved` is what stops that.
    @Test func theRemoteOpenCarriesResolvedSoTheViewerDoesNotDecideAgain() throws {
        let open = try Session.Overlay.Open.parse(["revdiff"])
        #expect(open.remoteOpenCommand(trigger: "t", row: "7b21").contains(" --resolved"))
        #expect(try Session.Overlay.Open.parse(["revdiff", "--resolved"]).makeRequest().args?.resolved == true)
        #expect(try Session.Overlay.Open.parse(["revdiff"]).makeRequest().args?.resolved == nil)
    }

    // MARK: - resolving this host's own name

    @Test func theSourceHostPrefersItsEnvironmentOverridesInOrder() {
        #expect(OverlayRedirectSsh.resolveSourceHost(
            environment: ["AGTERM_OVERLAY_SOURCE_HOST": "air.ts.net",
                          "AGTERM_REMOTE_OVERLAY_SOURCE_HOST": "legacy"],
            hostName: "p4air.local") == "air.ts.net")
        #expect(OverlayRedirectSsh.resolveSourceHost(
            environment: ["AGTERM_REMOTE_OVERLAY_SOURCE_HOST": "legacy"],
            hostName: "p4air.local") == "legacy")
        // an empty override is not an override: it falls through rather than resolving to ""
        #expect(OverlayRedirectSsh.resolveSourceHost(environment: ["AGTERM_OVERLAY_SOURCE_HOST": ""],
                                                     hostName: "p4air.local") == "p4air.local")
    }

    // Tailscale's own DNS name carries a trailing dot; ssh usage never does.
    @Test func theSourceHostStripsATrailingDotAndTreatsAnEmptyNameAsNothingToSshBackTo() {
        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: "air.ts.net.") == "air.ts.net")
        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: "") == nil)
        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: ".") == nil)
    }

    // The precedence chain in order: env var beats the config file, and the config file beats `hostname` —
    // the mDNS name that only resolves on the same LAN, kept last for a machine that configures nothing.
    @Test func theSourceHostPrefersTheConfigFileOverHostname() throws {
        let path = try writeConfig("# comment\n  self = air.ts.net  \n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: "p4air.local",
                                                      configPath: path) == "air.ts.net")
    }

    @Test func theSourceHostPrefersAnEnvVarOverTheConfigFile() throws {
        let path = try writeConfig("self=configured.example\n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        #expect(OverlayRedirectSsh.resolveSourceHost(
            environment: ["AGTERM_OVERLAY_SOURCE_HOST": "explicit.example"], hostName: "p4air.local",
            configPath: path) == "explicit.example")
    }

    @Test func theSourceHostFallsBackToHostnameWhenTheConfigFileIsMissing() {
        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: "p4air.local",
                                                      configPath: "/nonexistent/agterm-overlay-redirect.conf")
            == "p4air.local")
    }

    @Test func theSourceHostFallsBackToHostnameWhenTheConfigFileHasNoSelfLine() throws {
        let path = try writeConfig("host = other.example\n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: "p4air.local",
                                                      configPath: path) == "p4air.local")
    }

    // The five parsing rules `readConfiguredSelfHost` states, one case each. `agterm-zmx-test` runs the same
    // five against `read_overlay_redirect_self_host`: the two implementations must not drift, because a
    // disagreement is invisible from either side — one machine writes a name the other never ssh's to, and
    // the redirect degrades to a local overlay in silence.
    @Test func theConfigParserFollowsTheRulesTheShellHalfAlsoFollows() throws {
        func selfHost(_ contents: String) throws -> String? {
            let path = try writeConfig(contents)
            defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
            return OverlayRedirectSsh.readConfiguredSelfHost(path: path)
        }

        #expect(try selfHost("self=alpha.example\nself=beta.example\n") == "alpha.example")
        #expect(try selfHost("self=\nself=beta.example\n") == "")
        #expect(try selfHost("self=air.ts.net") == "air.ts.net", "no trailing newline")
        #expect(try selfHost("\tself\t=\tair.ts.net\t\n") == "air.ts.net", "tab-indented")
        #expect(try selfHost("self=air.ts.net\r\n") == "air.ts.net", "CRLF leaves no carriage return")
        #expect(try selfHost("self\n") == nil, "a line with no = is not a bare key")
    }

    // An empty first `self=` is "configured as nothing", so the chain moves on rather than reading a second
    // line the shell half would not read either.
    @Test func anEmptyConfiguredNameFallsThroughToHostname() throws {
        let path = try writeConfig("self=\nself=beta.example\n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: "p4air.local",
                                                      configPath: path) == "p4air.local")
    }

    // One contract, one file: exporting the override on the shell side used to leave Swift reading the
    // default path, so the two halves resolved this machine's name out of two different files.
    @Test func theConfigPathHonoursTheSameEnvironmentOverrideTheShellHalfDoes() throws {
        let path = try writeConfig("self=air.ts.net\n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        setenv("AGTERM_OVERLAY_REDIRECT_CONFIG", path, 1)
        defer { unsetenv("AGTERM_OVERLAY_REDIRECT_CONFIG") }

        #expect(OverlayRedirectSsh.defaultConfigPath == path)
        #expect(OverlayRedirectSsh.resolveSourceHost(environment: [:], hostName: "p4air.local") == "air.ts.net")
    }

    // Which names cannot work for an ssh back, and therefore earn the message naming the config file.
    @Test func anMdnsOrDotlessNameIsRecognisedAsLanOnly() {
        #expect(OverlayRedirectSsh.isLanOnly("p4studio.local"))
        #expect(OverlayRedirectSsh.isLanOnly("p4studio"))
        #expect(!OverlayRedirectSsh.isLanOnly("air.ts.net"))
    }

    // MARK: - the script directory

    // Every fallback path deletes the script it wrote; only the script that really runs cleans itself up.
    @Test func removingAScriptTakesItsWholeDirectoryAndRefusesAForeignPath() throws {
        let path = try OverlayRedirectSsh.writeSourceScript(cwd: NSTemporaryDirectory(), command: "true")
        let directory = (path as NSString).deletingLastPathComponent
        #expect(directory.hasPrefix(NSTemporaryDirectory()), "never /tmp: another local user owns that")

        let outsider = NSTemporaryDirectory() + "agterm-redirect-outsider-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outsider, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: outsider) }
        OverlayRedirectSsh.removeSourceScript(path: outsider + "/run.sh")
        #expect(FileManager.default.fileExists(atPath: outsider), "a path from elsewhere must be refused")

        OverlayRedirectSsh.removeSourceScript(path: path)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    // The failed-`cd` arm cleans up too: an early `exit 1` before the `rm -rf` leaks the directory for good.
    @Test func aScriptWhoseDirectoryIsGoneStillDeletesItsOwnTempDirectory() throws {
        let path = try OverlayRedirectSsh.writeSourceScript(cwd: "/no/such/directory", command: "true")
        let directory = (path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = [path]
        try run.run()
        run.waitUntilExit()

        #expect(run.terminationStatus == 1)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    // The other half of the same leak: a redirect the viewer never ran leaves a directory nothing revisits,
    // so writing a new script sweeps the abandoned ones. A pending one (written now) is never swept.
    @Test func writingAScriptSweepsDirectoriesOldEnoughToBeAbandoned() throws {
        let stale = NSTemporaryDirectory() + OverlayRedirectSsh.scriptDirectoryPrefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: false)
        let old = Date(timeIntervalSinceNow: -(OverlayRedirectSsh.abandonedScriptAge + 60))
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: stale)

        let fresh = try OverlayRedirectSsh.writeSourceScript(cwd: "/", command: "true")
        defer { OverlayRedirectSsh.removeSourceScript(path: fresh) }

        #expect(!FileManager.default.fileExists(atPath: stale))
        #expect(FileManager.default.fileExists(atPath: fresh))
    }

    // A second invocation must never land in the first one's directory: whichever script finishes first
    // `rm -rf`s it, taking the other's pending script with it.
    @Test func twoScriptsFromOneProcessNeverShareADirectory() throws {
        let first = try OverlayRedirectSsh.writeSourceScript(cwd: "/", command: "true")
        let second = try OverlayRedirectSsh.writeSourceScript(cwd: "/", command: "true")
        defer {
            OverlayRedirectSsh.removeSourceScript(path: first)
            OverlayRedirectSsh.removeSourceScript(path: second)
        }
        #expect((first as NSString).deletingLastPathComponent
            != (second as NSString).deletingLastPathComponent)
    }

    @Test func theTriggerParsesIntoASingleSshBackCommand() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try fakeProgram(named: "ssh", in: dir)

        let trigger = OverlayRedirectSsh.sshBackTrigger(sourceHost: "p4studio.local", scriptPath: "/tmp/d/1.sh")
        let run = try shell(trigger, path: dir)

        #expect(run.lines == ["-o", "ConnectTimeout=2", "-t", "p4studio.local", "sh /tmp/d/1.sh"])
    }

    // MARK: - helpers

    private func redirected(_ redirect: ControlOverlayRedirect, id: String) -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(id: id, overlayRedirect: redirect))
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "agterm-redirect-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(_ contents: String) throws -> String {
        let dir = try makeTempDir()
        let path = dir + "/agterm-overlay-redirect.conf"
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// A stand-in program that prints its own argv, one entry per line, so a generated command line can be
    /// checked against what a real shell hands the program it names.
    private func fakeProgram(named name: String, in dir: String) throws -> String {
        let path = dir + "/" + name
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n".utf8)
            .write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func shell(_ script: String, path: String? = nil) throws -> (lines: [String], status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        if let path {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        return (lines.map(String.init), process.terminationStatus)
    }
}

/// A recording stand-in for everything the redirect does outside the control socket.
private final class Effects: @unchecked Sendable {
    var requests: [ControlRequest] = []
    var responses: [ControlResponse] = []
    var ssh: [[String]] = []
    var scripts: [(cwd: String, command: String)] = []
    var removed: [String] = []
    var sshStatus: Int32 = 0
    var sourceHost: String? = "p4studio.local"
    var currentDirectory = "/w/repo"
    var scriptPath: String? = "/tmp/agterm-overlay-redirect-1/42.sh"

    func send(_ request: ControlRequest) throws -> ControlResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SocketClientError("no scripted response for \(request.cmd)") }
        return responses.removeFirst()
    }

    var environment: OverlayRedirectEnvironment {
        OverlayRedirectEnvironment(
            sourceHost: { [self] in sourceHost },
            currentDirectory: { [self] in currentDirectory },
            writeScript: { [self] cwd, command in
                scripts.append((cwd, command))
                guard let scriptPath else { throw SocketClientError("cannot write the ssh-back script") }
                return scriptPath
            },
            removeScript: { [self] path in removed.append(path) },
            runSsh: { [self] argv in
                ssh.append(argv)
                return sshStatus
            })
    }
}
