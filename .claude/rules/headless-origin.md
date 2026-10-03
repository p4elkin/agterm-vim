---
paths:
  - "agtermCore/Sources/agterm-headless/**"
  - "agtermCore/Sources/AgtermHeadlessKit/**"
  - "agtermCore/Tests/AgtermHeadlessKitTests/**"
  - "scripts/headless/**"
---

## Headless origin

The Linux server that acts as a remote origin: `docs/plans/20260929-headless-origin-spec.md` owns the design.

## Module boundary

`AgtermHeadlessKit` owns `HeadlessConfig`, `DaemonSurface`, the `Headless` model, `HeadlessActions`,
`HeadlessCatalog` and the zmx runner.
Its target and tests compile on both platforms; configuration takes an injected environment and uses
`ControlResolve.socketPath` for the control socket.
The Linux `agtermctl` defaults to that socket, `$HOME/.local/state/agterm-headless/agterm.sock`, so it needs no `--socket`.
The Linux executable owns `Socket.swift`, `Presentation.swift`, and `main.swift`.
`Headless` creates its stream adapter through a factory given its library and presentation hub.
`HeadlessStreams.adopt(session:fd:)` returns nil after taking ownership of the connection, including the
ok reply; a response leaves ownership with the control server.
`PresentationStreams` owns fd writes, active streams, hello deadlines, and heartbeats, and implements
`closeStreams(session:)` for session teardown.

## What the server serves

`ForwardPolicy.kind(of:)` in `agtermCore` is the one allowlist: every `Command` is served, forwarded to the
presenting Mac, routed per request (the overlay family, by `route(_:holdsJob:)`) or refused with a named reason.
Its switch has no `default`, so a new upstream command fails the build until it is classified.
`HeadlessCatalog.support(for:)` maps it, and `HeadlessCatalog.refusal` spells the one refusal text,
`<cmd> is not available on a headless origin: <reason>`.
`HeadlessActions` is the `ControlActions` conformer. Refused methods answer with the catalog's text, and
`respond(to:)` routes by the policy before the dispatcher and fills the dispatcher's nil answers
(`debug.appearance`) from the catalog.
`session.search` and `session.bookmark.go` share `searchSession`; only `respond(to:)` sees which one it was.
The socket server calls `HeadlessActions.serve` for every request. `serve` is the executable's only mode;
clients are the real `agtermctl`. `scripts/headless/smoke.sh` drives a throwaway server with it.
For an ok `zmx.present`, `serve` hands the connection to `adoptPresentation`, which revalidates the session;
nil means the stream adapter owns the connection and wrote the ok reply itself.
`version` and `tree` report `headless` plus the commit in a `BUILD` file next to the installed binary.

## Forwarding to the presenting Mac

`HeadlessForwarder` sends a forwarded request to the session's presenter as `control.forward` and waits 10 seconds
for `control.forwarded`; the frames are in [[control-api]]'s Remote sessions.
- It is refused, as `<cmd> cannot be forwarded: <reason>`, without a `--target` naming one of this origin's sessions by
  full id (`active` or a prefix does not count), with no presenter, with a presenter whose hello lacked `forward`, or
  over the frame limit. The deadline or the presenter leaving answers `the presenting Mac left`.
- It drops `window` and sends the full id; the Mac runs it on the one row bound to that session, so a flag or a
  focus lands on the presenting Mac's row only.
- A forwarded `pick.open` or `--url` open records its pick or page id with that presenter, and the polls go there.
  Once that presenter is gone a pick poll answers `cancelled` and a page poll `dismissed`. A pick id no Mac opened
  answers `unknown pick: <id>`. Closing the session forgets its ids.
- `--html` is refused: the file is on the origin.

## Program overlays

A program overlay takes the Mac origin's job path ([[control-api]], Remote sessions) with this server as the origin.
- The open books a job through `openRemoteOverlay(requireFollower: false)`: no pane here ever reports a lead, so
  the follower check would refuse every open. With no presenter it is refused at once.
- The launch context is the session's environment with no pane, since the program covers no daemon, plus
  `AGTERM_STATE_DIR`, `SHELL` and the server's `LANG`/`LC_*`: the helper's ssh login has no locale, and without
  one revdiff draws its UTF-8 as raw bytes.
  The cwd is an absolute `--cwd`, else the session's `effectiveCwd`, else `$HOME`; a relative `--cwd` is refused,
  having nothing on this origin to resolve against.
- The presenter runs `ssh -tt <origin> agtermctl session overlay run-job <job>`. `RemoteSession.runJobCommand`
  passes `-o ControlMaster=no -o ControlPath=none`, one connection per job: a shared multiplexed connection was
  measured refusing new channels with `Session open refused by peer`.
- On p4linux that `agtermctl` is the server's own CLI (agterm-agents links it there), and with no socket named
  it talks to the local server.
- `serve` hands an ok claim's connection to `HeadlessStreams.adoptJob`, which writes the reply; `OverlayJobLink`
  sends the launch context first, then a cancel that arrived before the adoption (`pendingJobCancels`).
  The helper gives the program the ssh terminal with `posix_spawn_file_actions_addtcsetpgrp_np` (glibc 2.35+).
- 30 seconds from open to claim and 10 from claim to `started`; a miss ends the job and frees the slot (a claimed
  job's helper is also sent a cancel), as do a rejection and a helper leaving without an outcome.
  A lost or changed presenter cancels an unclaimed job only: a claimed or running one keeps its slot until its
  helper reports, as [[control-api]]'s Remote sessions specifies. `result`, `close` and `resize`
  are answered here, `result` by the Mac's remote-branch rules.

## The zmx runner

`ProcessZmxRunner` spawns zmx with `posix_spawn` and reaps it with `waitpid` on a background thread.
corelibs `Process` on Linux reports termination only once every descendant holding its inherited
descriptors has exited, and `zmx run` leaves a daemon behind, so no deadline could hold with it.
The core is synchronous (a semaphore deadline, SIGTERM, SIGKILL after 0.25 s) and never awaits a task, so it
is safe from the main actor. Reaping, the output drain and `runInBackground` each use a dedicated `Thread`, never the global pool
(`DispatchQueue.global()`, `DispatchIO`): it does not grow while its workers block, and under the Mac's parallel
`swift test` a starved reaper or read handler turned every call into a timeout.
Every call has a 5-second deadline. Output drains on one thread per call polling both pipes, with a cancel
flag checked every 50 ms, so a descendant holding a pipe cannot hold the call either.
The child gets an empty signal mask and default dispositions: the caller may be a dispatch worker, which
blocks most signals, and a daemon inheriting that mask survives `zmx kill`.
⚠️ A served command whose `ControlActions` method is synchronous runs zmx on the main actor: a hung zmx
delays every other request through its timeout and, for a failed create, the cleanup kill.
Only `zmx.tree` (async), `session.type` and `DaemonWatcher`'s listing run zmx off it.

`session.type` writes into the pane's daemon with `zmx type` on stdin, paced like the Mac's `coveredType`, one
lane per daemon, and is never retried: the daemon may have queued input before failing. It is served, not
forwarded to a Mac, because a session viewed only on a closed laptop, or made on p4linux and not attached yet,
has no presenter while room delivery and the compact tools still type into it.

## The pane environment

`session.new` builds the daemon's environment with `SurfaceEnvironment.session` for the new session, plus
`AGTERM_STATE_DIR` and `SHELL` from the password database (`/bin/sh` when absent or empty).
zmx starts `$SHELL` as a login shell and types `sh -c <command>` into it, so no `-lc` wrapper is needed.
An omitted `--cwd` defaults to home; a relative path resolves against the server's working directory.
An explicit cwd must be an existing directory and contain no terminal controls; refusal precedes model creation.
The resolved path is both the stored cwd and the runner's working directory.
Without `--command`, send `run <daemon> -d sh -c true`: the patched zmx leaves its login shell at a prompt.
The list's `ended`/`exit_code` fields describe the typed task, not the daemon's lifetime.
The runner drops every inherited `AGTERM_*` key and `AGTERMCTL` before adding the call's own: the server may
itself run inside a remote pane, and a daemon carrying that pane's `AGTERM_SESSION_ID` reports to the
wrong session.

## Session lifecycle

Every pane is one zmx daemon, named `ZmxSupport.daemonName(for:)` from its pane identity.
`session.close` kills every pane's daemon, then closes the session whatever the kills answered, persists,
and ends its presentation streams (`closeStreams(session:)`).
`zmx.kill` kills one pane's daemon and closes that pane through `paneExited`; a failed kill changes nothing.
`Headless.paneExited` is the one path for a pane whose daemon ended: the split closes, a primary with a
split promotes the split, a lone primary closes the session.

`DaemonWatcher` runs `zmx list` every 5 seconds on a background thread and calls `paneExited`.
A pane counts as gone only once the watcher has listed its daemon and then stops listing it.
A daemon never listed may still be coming (a park replay restores after the server starts, and `zmx run`
returns before the listing shows it), so an unlisted pane waits `startupGrace` (10 minutes) from the
server's start, or from when the watcher first saw a pane created later.
The split is checked first, so a session losing both panes in one listing closes instead of promoting a
dead split. A failed or unparsable listing changes nothing.

## Split panes

A new split daemon is spawned before its layout is published; its preassigned identity must survive
`setSplitVisibility`, or the viewer would attach to a different daemon.
Left and right spawns share `Headless.paneEnvironment`; right uses its own stable pane token.
`session.split off` hides the split without killing its daemon; showing or transposing it reuses the pane.
A command requires mode `on` and an absent split, including when an existing split is hidden.
`session.split.close` reuses `killPane(.right)` and the watcher's `paneExited` path; a failed kill keeps the pane.
`session.swap` delegates to the store so identities, pane metadata, and the published layout move together.

## Pane text

`session.text` returns `zmx history <daemon>` for the addressed pane: there is no viewport, so the default
and `--all` read the same history. zmx has already dropped escapes and trailing blank rows.
`--lines N` keeps the last N content lines, the Mac surface reader's rule.

## Pane foreground

`tree` and `zmx.tree` report each pane's `foreground`/`foregroundShell`, as the Mac does, from procfs: the
daemon's login shell (its pid from `DaemonWatcher`'s last listing, `Headless.daemonLeaders`), the terminal's
foreground group in its `stat`, that group leader's `cmdline`, or once the leader is gone a member that
`CommandRestore.groupDescentCandidates` picks from a procfs scan.
A tree read never runs zmx itself, so a pane reports nothing until the watcher's first listing after it starts.

## HUDs and asks

A HUD is store state published as `hud` frames: `openHud` gets an empty helper command and file, so nothing
paints or writes a body on the server. `HeadlessActions` owns the auto-hide deadline, as the Mac's
`ControlServer+Hud.swift` does, and `onHudDiscarded` cancels it on every teardown.
The server calls `presentAsk`, never `presentAskRemotely`: it has no local surface, so the lead book's
follower check has nothing to fall back to.
With no presenter, an ask waits in the session slot with no remote owner, registered as a session ask, so
every existing end path (cancel, `session.close`, split close) ends it. It is never drawn on the server.
`Headless.attachAskPresentation` wires the hub:
- `onPresenterChanged` re-offers a waiting or presented ask with `includeWaiting: true`;
- `onPresenterWillChange` dismisses to the old holder, which reaches a live stream only on a take (Phase 6);
- `onPresenterLost` calls `takeAskBack`, never `takeBackRemoteAsk`, so the ask waits again;
- an `ask.rejected` that `isPresentingRemotely` confirms ends it `cancelled` with `presentation-lost`.
`gui` asks are refused: a Mac rejects a GUI replica whenever the row is not on screen, and with one Mac the
ask would wait for a presenter change that never comes. The spec records the decision.

## Mac side: create and follow

`zmx.new` (contract in [[control-api]], "Remote sessions") has 12 consumers:
- core: `Command.zmxNew`, the zmx dispatch group, `dispatchZmxCommand`'s arm with its host and name checks,
  and `ControlActions.createAttachableSession` and `createRemoteSession`, each with a refusing default;
- CLI: `Zmx.New`;
- server: `HeadlessActions.createAttachableSession`, which is `session.new`'s path, and the catalog;
- Mac: `ControlServer.createRemoteSession`, `RemoteSession.newCommand`, the app's fallback switch and
  `waitsOnNetwork`.

`presenter.take` has 11: the frame case, its kind name, decode and encode; `PresenterGrant.transfer`; the
hub's take arm; the client's `takePresenter` and ignore arm; the client's hello arm reading its lead query;
the Mac's `roleChanged` hook (`ControlServer.paneLeadChanged`); the server's will-change dismiss; and the
Mac origin's two callbacks. The hub fires `onPresenterWillChange` while the old holder still holds, so the
dismiss reaches a live stream, which a release never can.

## Mac side: saved rows and row states

The row book, its write rule, the launch and reopen restore and the supervisor are specified in
[[control-api]], "Remote sessions". `remoteState` has 7 consumers: `RemoteRowState` and
`RemotePresentationState.rowState`, `ControlSessionNode.remoteState` and its producer beside `remoteHost`,
the sidebar notice through `RemotePresentationState.rowNotice(host:)`, the supervisor through
`AppStore.setRemoteRowState`, the tree read-back tests, and the bundled skill's session-node list.

## Install, service and versions

`scripts/headless/install.sh` builds both products in release mode and zmx at `setup.sh`'s `ZMX_REV` with every
`scripts/zmx-patches/*.patch`, for the host's Linux target, and installs them with `BUILD` into
`~/.local/opt/agterm-headless/`. A stamp of revision, target and patch digest skips an unchanged zmx build.
Files land by atomic rename, so a running server never sees a half-written binary.
It installs `agterm-headless.service` as a user unit (the user has `Linger=yes`), starts it when stopped, and
restarts it only when the server binary changed. A server running outside systemd is left alone with a hint.
The unit sets `KillMode=process`: the zmx daemons the server starts are in its cgroup, and the default mode
would end every session on a restart. A restart loses only presentation streams, which the Mac reconnects.
Park and replay (`agterm-zmx-park --zmx <bin> --zmx-dir <dir>`, in agterm-agents) carry the server's daemons
across a reboot under their original names, keyed to a separate park state per zmx directory.
The replay unit is ordered `Before=agterm-headless.service`: a restored pane whose daemon is not listed within
`DaemonWatcher.startupGrace` (10 minutes) of the server's start closes, and a slow replay (60 seconds per
`zmx run` at worst) could outrun that. The server therefore starts late at boot, never early.
`scripts/headless/check-version.sh <mac>...` fails when a Mac speaks another presentation version, and only
warns on a different or missing commit: the presentation version is what a stream must agree on.

## Linux test gate

`swift test --no-parallel` from `agtermCore/`, with swiftly's `swift` (Swift 6.2.4).
The Phase 0 baseline passed 4193 tests in 175 suites.

- Over a non-interactive ssh, source `~/.local/share/swiftly/env.sh` and put a real node first on PATH
  (`~/.local/share/mise/installs/node/26/bin`): the mise shim answers `node is not a valid shim` there,
  and every `OpenCodeStatusHookTests` case fails on it (measured 2026-10-03).
- An upstream file using `@Observable` with only `import Foundation` compiles on the Mac and fails here:
  swift-corelibs does not re-export `Observation` (`RemoteReconnect.swift`, 2026-10-03).

- Serial, not parallel: `SocketClientTests` captures the process-global `STDOUT_FILENO`, and a test in
  another suite writing to stdout meanwhile lands in its pipe (`runEchoesNewIdForCreateCommand` reads
  `ok\n` extra). `.serialized` orders only its own suite.
- Darwin-only, guarded with `#if canImport(Darwin)`:
  - whole files: `CodexStatusHookTests` (imports Darwin), `QuitReasonTests` (Apple events),
    `HudMarkdownTests` (the markdown renderer is plain text on Linux), `HudHelperTests` (the Mac-side
    `hud.sh` painter; the headless origin has no surface to paint, and why the suite hangs here is unproved);
  - single tests: the `TerminfoInstallTests` that spawn ssh, infocmp or a login shell (`posix_spawn` is
    `ENOSYS` on Linux by design), `ControlDispatcherHudTests.markdownThatRendersNothingIsNoMessage` and
    three `HudTests` markdown bodies (the markdown fallback), `OverlayRedirectSshTests`' abandoned-directory
    sweep (its fixture sets a creation date, which Linux cannot), and `SocketClientTests`' two
    held-ownership-lock tests (the `F_GETLK` probe is Darwin-only and answers nil elsewhere).
- Sockets on Linux: Glibc has no `SO_NOSIGPIPE`, so every write to the app's socket goes through
  `send(..., MSG_NOSIGNAL)` (`SocketClient.writeAll`, `StreamBridge.sendAll`). A plain `write` there kills
  the CLI with SIGPIPE when the app closes first.
- `RemoteSessionTests`' non-POSIX login shell test runs only where `/bin/tcsh` exists.
