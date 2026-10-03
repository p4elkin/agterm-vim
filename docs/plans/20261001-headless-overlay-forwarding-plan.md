# Plan: one generic forward for what the headless server cannot do

Spec: `docs/plans/20261001-headless-overlay-forwarding-spec.md`; read its "Risks, assessed first" before
any task. Builds on Phases 5 to 8 of `docs/plans/20260929-headless-origin-plan.md`, whose Phase 8 Task 46
install and Task 47 wait for this plan.

## Contents

- [Conventions](#conventions)
- [Phase 1: typing on the server](#phase-1-typing-on-the-server)
- [Phase 2: the forward](#phase-2-the-forward)
- [Phase 3: program overlays on the job path](#phase-3-program-overlays-on-the-job-path)
- [Phase 4: tools](#phase-4-tools)
- [Phase 5: headless rows in the remaining tools](#phase-5-headless-rows-in-the-remaining-tools)
- [Before the Phase 8 moves](#before-the-phase-8-moves)
- [Phase 8 moves, 2026-10-02/03](#phase-8-moves-2026-10-0203)
- [Order against Phase 8](#order-against-phase-8)

## Conventions

- agterm-vim work happens on branch `headless-phase8`; agterm-agents work on branch `headless-phase8`
  in the worktree `~/dev/agterm-agents-headless`. Nothing merges or installs before the order at the end
  allows it.
- **Linux gate**, from `agtermCore/`: `~/.local/share/swiftly/bin/swift test --no-parallel`, then
  `swift build --product agterm-headless` and `swift build --product agtermctl`. Delete `.build` first
  when a public type's stored fields changed: incremental builds have crashed on a stale layout.
- **Mac gate** on p4studio: `swift test` over plain ssh with `</dev/null`; `make lint` and
  `make test-app` in a Mac row. The upstream failure
  `HtmlOverlayRegistryTests.testAFolderGrantKeepsFilesOutsideItOut` (#659) is known.
- **agterm-agents tests:** `uv run --no-project --with pytest python -m pytest <files> -q`.
- Tests that start a real server or CLI on Linux pass `--socket` explicitly: the Linux default socket is
  the live server's since commit `c26e4343`.
- A phase that lands a user-visible feature updates `FORK-NOTES.md` and `CHANGELOG-fork.md` in the same
  commit, plus `.claude/rules/headless-origin.md`.
- When a command changes support kind, update `HeadlessCatalog`, `HeadlessCatalogTests` and
  `HeadlessRequests` together.
- ⚠️ A live check that needs a new Mac build needs an agterm restart on that Mac. That is Sasha's action.

## Phase 1: typing on the server

Solves: room delivery, the compact tools, `offload.sh`, the ralphex launcher and `pair.sh` cannot type
into a headless pane, including one with no Mac attached. Size S to M.

### Task 1: the zmx runner takes stdin

- [x] Tests first in `ZmxRunnerTests`: a run with input bytes delivers exactly those bytes to the child's
  stdin (`/bin/cat`), the child sees end of input, and a child that exits without reading neither hangs
  nor kills the test process.
- [x] Add an optional `input: Data?` to `ZmxRunning.run`, its default-argument extension and
  `runInBackground`, and a stdin pipe in both `ChildProcess.spawn` branches (Darwin and Glibc): the parent
  closes its read end after the spawn and writes on its own thread; `EPIPE` ends the write. The test
  process does not ignore `SIGPIPE`, so the writer blocks it on its own thread.
- [x] Consumers of the new parameter, 5: `ZmxRunning.run`, the extension, `runInBackground`, the real
  runner, `FakeZmxRunner`, which records the input.
- [x] Acceptance: `swift test --no-parallel --filter ZmxRunnerTests` from `agtermCore/`.

### Task 2: `session type` through `zmx type`

- [x] Tests first in `HeadlessActionsTests`, with `FakeZmxRunner`:
  - text from `--stdin` and from an argument reaches `zmx type <daemon>` of the left pane, and with
    `--pane right` the right pane's daemon, in the segments and with the separate Return the Mac's
    `coveredType` produces (`KeystrokeSegments`);
  - a pane with no daemon is refused with a reason naming the pane, and zmx is not called;
    `--pane scratch` is refused; `--select` is refused with a reason, and plain text is still typed;
  - a failed `zmx type` is reported and never retried;
  - two concurrent calls on one pane never interleave one call's text with the other's Return;
  - typed input clears an agent status through `agentIndicator.clearedBy(pane:keystroke:reset:)` with
    the server's default reset rule, and a `status` frame reaches the viewers; an empty payload clears
    nothing, as on the Mac.
- [x] Implement `HeadlessActions.typeSession` with one serial lane per pane, run through
  `runInBackground` off the main actor.
- [x] `HeadlessCatalog`: `.sessionType` moves from "no terminal surface" to served.
- [x] Acceptance: `swift test --no-parallel --filter 'HeadlessActionsTests|HeadlessCatalogTests|HeadlessCoverageTests'`.

### Task 3: docs for typing

- [x] `.claude/rules/headless-origin.md`: `session type` is served through `zmx type`, never retried, and
  why it is not forwarded (the closed-lid and not-yet-attached cases).
- [x] `plugins/agterm/skills/agterm/reference.md`: `session type` works in a headless session with no Mac.
- [x] `FORK-NOTES.md`, `CHANGELOG-fork.md`.
- [x] Acceptance: `grep -q 'zmx type' .claude/rules/headless-origin.md && grep -qi 'zmx type' CHANGELOG-fork.md`

Phase 1 gate: Linux gate, Mac gate.

Live check, with Sasha present: install the server. In a headless session with no Mac attached, deliver
a room message to it and run `compact-ask` there. The text and the Return arrive once each.

## Phase 2: the forward

Solves: flag, select, pages, pick, bookmarks and the clipboard commands are refused in a headless pane.
Size M. Program overlays stay refused until Phase 3.

### Task 4: `ForwardPolicy`, shared by both sides

- [x] Tests first in `ForwardPolicyTests` (agtermCore): `route(_:holdsJob:)` of a request answers `served`,
  `job`, `forwarded` or `refused`, checked against an explicit expected list for every command in the
  spec. The overlay family is routed per request: `open` with a command is `job`, with `--url`
  `forwarded`, with `--html` `refused`; `result` without `--page` is `served`; `close` and `resize` are
  `served` when the server holds a job for that pane, else `forwarded` (the policy takes that fact as an
  input). `session scratch`, `surface zoom`, `surface cursor` and `session type --select` are refused. In
  `HeadlessCoverageTests`, every request in `HeadlessRequests.all` has a route.
- [x] Add `ForwardPolicy` (a new fork file in agtermCore) with an exhaustive switch over `Command` and no
  `default`, so a new upstream command fails the build until it is classified. This task adds
  the `forwarded` and `routed` kinds to `HeadlessSupport`; `HeadlessCatalog` derives both from
  `ForwardPolicy`, so there is one allowlist. Consumers, 4: `HeadlessCatalog.support(for:)`,
  `HeadlessCatalogTests`, the exhaustive switch in `HeadlessCoverageTests`, and `HeadlessActions.refuse`,
  which keeps refusing both kinds until Task 7 adds the forwarder. The Mac re-checks the policy before running a forward.
- [x] Acceptance: `swift test --no-parallel --filter 'ForwardPolicyTests|HeadlessCatalogTests|HeadlessCoverageTests'`.

### Task 5: the frames

- [x] Tests first in `PresentationFramesTests`: `control.forward` and `control.forwarded` round-trip
  through `PresentationCodec`; an older reader decodes them as `unknown`.
- [x] Add `PresentationForward` (request id, `ControlRequest`) and `PresentationForwarded` (request id,
  `ControlResponse`), the two `Body` cases, their kind names and codec arms. Put both cases on the
  ignored line of `RemotePresentationClient.apply`'s exhaustive switch, so the build holds; Task 8 gives
  `control.forward` its own arm.
- [x] Consumers, 7: the two `Body` cases, `kind` names, decode, encode, the encoder's no-payload list,
  the hub's receive arm (Task 6), the client's receive arm and its ignored list (Task 8).
- [x] Acceptance: `swift test --no-parallel --filter PresentationFramesTests`.

### Task 6: the hub routes forwards

- [x] Tests first in `PresentationHubTests`, with the existing test sink: the hub keeps each subscriber's
  hello `kinds`; `presenterSupports("forward", session:)` is true only for a presenter that listed it;
  `control.forwarded` from the presenter reaches `onPresenterFrame`, and from a mirror it is dropped.
- [x] Store each hello's raw `kinds` per subscriber, not the list filtered through
  `PresentationHub.supportedKinds` (which stays without `forward`: the client adds it only with its effect); add `presenterSupports(_:session:)`; add `.controlForwarded` to the
  presenter-only arm of `receive`, next to `.askResolve`.
- [x] Acceptance: `swift test --no-parallel --filter PresentationHubTests`.

### Task 7: the server's forwarder

- [x] Tests first in `HeadlessForwarderTests` (AgtermHeadlessKitTests), with the real `PresentationHub`
  and a test sink:
  - a `pick result <id>`, `pick cancel <id>` or page poll is looked up in the id table BEFORE the target
    rule, and forwarded with its id untouched;
  - an allowlisted request whose target is a server session, given as a prefix, is sent with the full id,
    `window` dropped, and a fresh request id; the reply answers the caller;
  - no target, or a target that is not a server session: refused, nothing sent;
  - no presenter: "no Mac is presenting this session"; a presenter without `forward`: "the presenting
    Mac does not support forwarding";
  - a request over `PresentationCodec.maxFrameBytes`: refused before sending;
  - no reply within 10 seconds, or the presenter's stream ends: "the presenting Mac left";
  - a forwarded `pick open` reply's id is recorded; `pick result <id>` and `pick cancel <id>` go to the
    same presenter; after that presenter's stream ended, `pick result` answers `cancelled` at once;
  - a forwarded page's `pageID` is recorded; a poll by `pageID` goes to the same presenter, and answers
    `closed` once it is gone.
- [x] Add `HeadlessForwarder` (a new fork file), owned by `Headless`. `HeadlessActions.respond(to:)` asks
  `ForwardPolicy.route(request, holdsJob:)` first for every request, with `holdsJob` read from the
  session's `remoteOverlays` slot for that pane, and calls the forwarder on `forwarded`, before the
  dispatcher. Tests through `respond(to:)`: `open --url`, `result --page <id>`, and `close` with no job
  are forwarded.
- [x] Deliver replies through the existing `hub.onPresenterFrame` switch in `Headless`, as a new case.
  The hub callbacks are single closures that `Headless.attachAskPresentation` already sets: extend them,
  never replace them; `HeadlessAskTests` must still pass.
- [x] `HeadlessActions.refuse` stops refusing the two kinds Task 4 added, now that the forwarder answers them.
- [x] Acceptance: `swift test --no-parallel --filter 'HeadlessForwarderTests|HeadlessCatalogTests|HeadlessCoverageTests|HeadlessAskTests'`.

### Task 8: the Mac client answers forwards

- [x] Tests first in `RemotePresentationClientTests`: a received `control.forward` calls the
  `controlForward` effect and sends `control.forwarded` with the same request id and the effect's
  response; a response that does not fit the frame limit is replaced by ok:false "reply larger than the
  frame limit"; the default effect answers "not supported"; the hello lists `forward` only when the
  effect is set.
- [x] Add `controlForward` to `RemotePresentationEffects` as an effect with a completion, because the
  Mac's dispatch is async; add the receive arm.
- [x] Consumers: the effects struct, its initializer, the 3 `RemotePresentationEffects(` call sites, the
  receive arm, `supportedKinds`.
- [x] Acceptance: `swift test --no-parallel --filter RemotePresentationClientTests`.

### Task 9: the Mac executor

- [x] Hosted tests first in `RemoteForwardTests` (agtermTests), with a remote row bound to a server
  session:
  - `session flag on` naming the server's session id flags this row, and no other row;
  - a target naming another server session, or a session this stream does not present: refused;
  - a request `ForwardPolicy` refuses, or one carrying `command`: refused, nothing changes or starts;
  - a forwarded `session overlay open --url` answers with a `pageID`;
  - the Mac re-checks `ForwardPolicy` with `holdsJob` false, so a forwarded `close` or `resize` is allowed;
  - `pick open` opens in the window holding the row;
  - a forwarded `pick result <id>` and a page poll reach the dispatcher with the id unchanged and no
    target rewrite;
  - a reply carrying this row's id is mapped back to the server's session id.
- [x] Add `agterm/Control/ControlServer+Forward.swift` (a new fork file): map the server's session id to
  this row through its binding, re-check `ForwardPolicy`, set the row's window, and run the request
  through `ControlServer.dispatch`, made internal, which reaches the core dispatcher and, for what the
  dispatcher does not handle, the app switch. Map ids in the
  reply back. Wire it as the `controlForward` effect in `remoteEffects(for:)`.
- [x] Acceptance: `scripts/test-app.sh -only-testing:agtermTests/RemoteForwardTests` on p4studio.

### Task 10: `pick --target`

- [x] Tests first in `agtermctlKitTests/CommandsTests.swift`: `pick` sends `target` from `--target`,
  else from `AGTERM_SESSION_ID`, else none.
- [x] Add `--target` to `Pick` in `agtermctlKit/MiscCommands.swift`. The core dispatcher is not changed:
  the Mac executor turns a forwarded pick's target into the row's window, so pick calls made on the Mac
  are unaffected.
- [x] Acceptance: `swift test --no-parallel --filter CommandsTests`.

### Task 11: the Mac tree reads back the bound server session

- [x] Tests first in `agtermCoreTests` (tree projection): a remote row bound to a server session reads
  back `remoteSession` with that id; a local row and an unbound row omit it.
- [x] Add `remoteSession` to `ControlSessionNode`, set in `AppStore`'s tree projection beside `remoteState`,
  omitted when nil; a test decodes a node without it.
- [x] Consumers, 5: `ControlSessionNode`, the projection in `AppStore`, the skill's `reference.md`,
  `.claude/rules/control-api.md`'s tree read-back list, `agterm-open-path` (Task 19).
- [x] Acceptance: `swift test --no-parallel --filter AppStoreTreeProjectionTests`.

### Task 12: docs for the forward

- [x] `.claude/rules/headless-origin.md`: the forward, `ForwardPolicy` as the one allowlist, the
  refusals, the id table, the flag landing on the presenting Mac's row only.
- [x] `.claude/rules/control-api.md`, remote sessions: the `control.forward` frames, the `forward` hello
  kind, `remoteSession`.
- [x] `plugins/agterm/skills/agterm/reference.md`: what works in a headless pane and why; `pick --target`.
- [ ] `.claude/rules/fork-merge.md`: decide with Sasha whether `PresentationHub.swift`'s presenter-only
  arm and `ControlServer+Forward.swift` join `flagged`, as `release.md` asks.
- [x] `FORK-NOTES.md`, `CHANGELOG-fork.md`.
- [x] Acceptance: `grep -q ForwardPolicy .claude/rules/headless-origin.md && grep -q 'control.forward' .claude/rules/control-api.md`

Phase 2 gate: Linux gate, Mac gate.

Live check, after deploying the server and p4studio (Sasha restarts agterm). Passed 2026-10-01 at `bcbe00e2`. From a headless pane with
p4studio presenting:

- `agtermctl session flag on --target "$AGTERM_SESSION_ID"` flags the row on p4studio;
- `agtermctl pick` with two items opens on p4studio and prints the choice on p4linux;
- `agtermctl session overlay open --url https://example.com --target "$AGTERM_SESSION_ID"` opens a page (plain `http` fails to load: App Transport Security);
- `agtermctl session type --target "$AGTERM_SESSION_ID" hi` into a row p4studio has not drawn since its
  launch still arrives;
- with the Mac row closed, `session flag` is refused with "no Mac is presenting this session".

## Phase 3: program overlays on the job path

Solves: revdiff, `agterm-open-at` and other program overlays from a headless pane. Size M.

### Task 13: the server books program overlays

- [x] Tests first in `HeadlessOverlayJobsTests` (AgtermHeadlessKitTests), with the real hub and a sink:
  - `session overlay open <command>` with a presenter and NO lead ever reported books a job and sends
    `overlay.request` to the presenter; the open answers ok with the session id;
  - the job's `OverlayLaunchContext` carries the command, the cwd, the server's session environment with
    no pane, `AGTERM_STATE_DIR` and `SHELL`;
  - with no `--cwd` the cwd is the session's stored cwd, else `$HOME`; a relative `--cwd` is refused;
  - `result` and `--block` polls are answered by the server; `close` and `resize` send `overlay.close`
    and `overlay.resize`;
  - no presenter: refused at once;
  - an `overlay.rejected` from the presenter makes `result` answer `overlay ended: launch-failed`;
  - no claim within the job's launch window: `result` answers `launch-failed`, and the slot is free;
  - the presenter is lost before the claim: `canceled`; the presenter changes: the old slot is closed.
- [x] In core `AppStore.openRemoteOverlay` add a `requireFollower` parameter, default `true`:
  `agtermCore` is a public library with callers outside this repo. The server passes false. A core test: with `requireFollower` false and no lead, the open proceeds; the Mac's
  existing tests still pass with true.
- [x] Reuse the core `AppStore+RemoteOverlay` methods (`openRemoteOverlay`, `closeRemoteOverlay`,
  `resizeRemoteOverlay`, `finishRemoteOverlay`, `remoteOverlayPresenterLost`, `rejectRemoteOverlay`,
  `remoteOverlaySurfaceClosed`). Port only what lives in the app today: the expiry timers
  (`scheduleOverlayJobExpiry`) and the remote branch of `sessionOverlayResult`. Pending cancels moved to
  Task 14: only a claim registers a cancel hook.
- [x] Wiring, 9 consumers: one `OverlayJobs` owned by `Headless`, set as `store.overlayJobs` in
  `Headless.init` and in `newSession`; `jobs.onFinished` calls `finishRemoteOverlay`; the expiry timers;
  `onPresenterWillChange` sends `overlay.close` per slot; `onPresenterChanged` and `onPresenterLost` call
  `remoteOverlayPresenterLost`; `onPresenterFrame` gains `.overlayRejected` and `.overlayClosed` arms. The
  hub callbacks are single closures the ask code in `Headless` already sets: extend them, never replace.
- [x] Acceptance: `swift test --no-parallel --filter 'HeadlessOverlayJobsTests|AppStoreRemoteOverlayTests|ForwardPolicyTests'`.

### Task 14: the claim and the job stream on the server

- [x] Tests first in `HeadlessOverlayJobsTests`, with a fake streams adapter: `session overlay run-job
  <job>` claims a booked job; a second claim, an unknown job, or an expired one is refused; after the ok
  reply the adapter receives the job, the context frame is sent first, then any queued cancel; a reported
  `exited(n)` ends the job with status n; a failed reply write calls `helperGone`; a claimed job whose
  helper never reports `started` expires after the start window and frees the slot.
- [x] Add `HeadlessStreams.adoptJob(fd:reply:onLine:onClose:)`, its Kit-side half tested with the fake, and a `JobStream`
  in the executable, modelled on `PresentationStream`. Serve `claimOverlayJob` and special-case
  `.sessionOverlayJobRun` in `HeadlessActions.serve` the way `ControlServer.handleConnection` does.
- [x] Schedule the start-window expiry on claim, as the Mac's `claimOverlayJob` does. The pending cancels
  Task 13 left for here live in `Headless` beside the job links. `HeadlessCatalog`:
  `.sessionOverlayJobRun` moves to served.
- [x] Add the claim, context and exit path to `scripts/headless/smoke.sh`.
- [x] Acceptance: `swift test --no-parallel --filter HeadlessOverlayJobsTests && scripts/headless/smoke.sh`.

### Task 15: the Linux spawn in `OverlayRunJob`

- [x] Tests first in `agtermctlKitTests`, Linux only: `OverlayRunJob.run` spawns the command in the
  helper's pty with the context's environment and cwd, makes it the terminal's foreground process group,
  and returns its exit status. A real-pty end-to-end test runs the helper against a test server on its
  own `--socket`, wrapped in `timeout`, so a helper stopped by `SIGTTIN` fails the run instead of
  hanging it.
- [x] Implement the Glibc branch with `posix_spawn_file_actions_addtcsetpgrp_np` (glibc 2.35 or newer);
  the Darwin branch is unchanged. Remove `programOverlaysReportUnsupportedOnLinux` and lift the
  `#if canImport(Darwin)` guards from the `OverlayRunJobTests` that now apply on both platforms.
- [x] Acceptance: `swift test --no-parallel --filter 'OverlayRunJobTests'`.

### Task 16: `runJobCommand` opts out of ssh multiplexing

- [x] Test first in `RemoteSessionTests`: `runJobCommand` argv carries `-o ControlMaster=no` and
  `-o ControlPath=none` before the host.
- [x] Implement in `RemoteSession.runJobCommand`.
- [x] Acceptance: `swift test --no-parallel --filter RemoteSessionTests`.

### Task 17: the shim sends `run-job` to the server

- [x] Tests first in agterm-agents `tests/test_agterm_ctl_remote.py`: `agtermctl session overlay run-job
  <job>` with no `AGTERM_SOCKET` goes to the installed headless server's socket, never to the Mac.
- [x] Implement in `bin/agterm-ctl-remote`'s `headless_call`: p4linux is never a Mac origin. Task 47
  removes it with the shim.
- [ ] Land it as its own commit and cherry-pick it onto agterm-agents `main` with Sasha's approval: the
  live shim runs from `main`, and the branch also carries Task 42, which must not ship early.
- [x] Acceptance: `cd ~/dev/agterm-agents-headless && uv run --no-project --with pytest python -m pytest tests/test_agterm_ctl_remote.py -q`

### Task 18: docs for program overlays

- [x] `.claude/rules/headless-origin.md`: the job path on the server, `requireFollower`, the cwd rule, why
  `runJobCommand` opts out of multiplexing, and the shim route until Task 47.
- [x] `plugins/agterm/skills/agterm/reference.md`: program overlays work in a headless pane.
- [x] `FORK-NOTES.md`, `CHANGELOG-fork.md`.
- [x] Acceptance: `grep -q 'run-job' .claude/rules/headless-origin.md && grep -q 'ControlMaster=no' .claude/rules/headless-origin.md`

Phase 3 gate: Linux gate, Mac gate.

Live check, after deploying the server, p4studio (Sasha restarts agterm) and the shim route on p4linux.
Passed 2026-10-01 at `da117832`; the first run at `34936d2f` showed revdiff's UTF-8 as raw bytes (the overlay had
no locale), fixed by `da117832`. The status state is `active`: `working` is not a state. From a headless pane:
`agterm-open-at <file>:<line>` opens revdiff on p4studio, showing the p4linux file;
`agtermctl session overlay open "sh -c 'exit 3'" --target "$AGTERM_SESSION_ID" --block` exits 3;
inside an overlay, `agtermctl session status active --target "$AGTERM_SESSION_ID"` changes the headless
session's status.

## Phase 4: tools

Solves: `agterm-open-path` refuses headless rows; `agterm-review-live` cannot see the Mac's reader.
Size S. Work in `~/dev/agterm-agents-headless`.

### Task 19: adopt and fix `agterm-open-path`

- [x] Diff `~/.local/bin/agterm-open-path` on p4studio and on p4linux; adopt the newer into
  `bin/agterm-open-path` and say which in the commit. `install.sh` links every file under `bin/`.
- [x] Tests first in `tests/test_agterm_open_path.py`, with a fake `agtermctl`: a click on a headless
  row (one with `remoteSession`) runs the open on p4linux against that server session; a remote row
  without `remoteSession` is still refused.
- [x] Implement, reading `remoteSession` from the Mac tree (Task 11).
- [x] Acceptance: `uv run --no-project --with pytest python -m pytest tests/test_agterm_open_path.py -q`

### Task 20: `agterm-review-live` reads the reader through the forward

- [x] Tests first in `tests/test_agterm_review_live.py`: on a headless row, `reader_is_up` asks through
  a forwarded `session overlay text` on the reader's pane, not the p4linux `tree`; on a Mac row it is
  unchanged.
- [x] Implement in `bin/agterm-review-live`.
- [x] Acceptance: `uv run --no-project --with pytest python -m pytest tests/test_agterm_review_live.py -q`

### Task 21: docs for the tools

- [x] agterm-agents `README.md` and `docs/headless-migration.md`: both tools work on headless rows.
- [x] Acceptance: `cd ~/dev/agterm-agents-headless && grep -q 'agterm-open-path' docs/headless-migration.md`

Phase 4 gate: the agterm-agents suite, with no failure beyond those that also fail on `main`.

Live check, after `install.sh` on p4studio: Shift+Cmd+click on a path in a headless row on p4studio opens
the p4linux file; a live revdiff review started in a headless pane opens.

## Phase 5: headless rows in the remaining tools

Solves: Mac chords that decide "local or remote" from `remoteHost` or a row's command line misread a headless row.
Found in Phase 4's live check, 2026-10-01, and in Task 23's audit. Size L.

Already done in that live check, each peer-reviewed and installed with Sasha's approval:
- agterm-vim `27ac251a`: the server's `tree` and `zmx.tree` report each pane's `foreground` from procfs.
- agterm-agents `5320478`: `agterm-plannotate` follows a page the server's tree never shows (first proxy request,
  then `overlay result --page`). Without it every plannotator page from a headless row died after 15 s.
- agterm-annotate `d78611d`: the annotate chord runs on the host against the server's session id.
- Live-checked by Sasha in `p4-live` on 2026-10-01: the annotate chord pastes the notes back, and a plannotator page
  from a headless row stays open past 15 s.
- revmux `headless-forward` (`codex-claude`): round 01 had 3 majors and 6 minors, fixed in `b85e1303` and `e5d97c12`
  (presenter loss was a doc error: a running job keeps its slot by contract); round 02 (`final`) found nothing.

### Task 22: the chat-room reader on a headless row

- [x] `agterm-chat-pane` (with `agterm-row-origin`) refused a headless row: "origin row is unknown". The guess here
  was a reader on the host with `--presented`; that is wrong. The agent pairs under the server's session id and
  `session-chat-pairing.py` ships that pairing to the Mac's store, so the reader runs on the Mac, over the Mac
  row's right pane, with `--row <server id>`. `agterm-row-origin` exits 4 with `{"host", "session"}`; a row with no
  right pane is split on the server, which grows it on the Mac. agterm-agents `617257a`.
- [x] A reply from that reader: `rooms-deliver.py` finds the server id as a Mac row's `remoteSession`, guards on the
  server's tree (the Mac node's `foreground` is the ssh transport) and types through the server's own CLI, via the
  new `agterm-headless-ctl`. Live on 2026-10-02: a probe typed into `p4-live`'s Claude, which answered in the room.
- [x] Peer finding: a row viewing another Mac also carries `remoteSession` and no pin, so every headless check takes
  a host list, `AGTERM_HEADLESS_HOSTS` (default `p4linux`): row origin, `rooms_pane.headless_rows`,
  `agterm-zmx headless_of`, the attach picker, open-link and open-path.
- [ ] Live check from the laptop: a headless row presented by p4air pairs into p4air's store. Unknown whether the
  server session is labelled with the presenting Mac; if not, the reader on p4air is empty, and the chord should
  refuse a headless row whose presenter is not the pairing hook's target.
- Left for later: the SessionStart restore hook on p4linux cannot open the reader for a headless row (exit 7, as for
  mosh rows); `rooms-deliver --pane-only` does not take the headless route. Pre-existing on every p4linux row: the
  pointer names the Mac's body path, and the reply clause's bare `rooms-write.py` is not on the far PATH.

### Task 23: audit the remaining tools

- [x] Grep every chord and tool in agterm-agents, agterm-annotate and `~/.config/agterm/keymap.conf` for
  `remoteHost`, `restoreCommand` and `AGTERM_REMOTE_SELF_HOST`; list each one that misreads a headless row.
- [x] Sasha picks which to fix before the Phase 8 moves; the rest wait for Task 47. Picked on 2026-10-02: Tasks 25
  to 27. Waiting: the FZF chords, the vifm and Lazygit overlays (Mac cwd, as on pinned rows), `agterm-zmx pick`
  and `agterm-park` (not traced), and `--workspace-name` on `agterm-zmx new --host`.

### Task 25: the end-agent chord ends the server session

- [x] `agterm-zmx kill` and `history` take the host only from a pinned command, so on a headless row `kill` closes
  the Mac row and leaves the server session running. Confirmed live on 2026-10-02 with a probe row.
- [x] With `remoteHost` and `remoteSession` and no pin: `kill` ends the server session with the server's own CLI,
  `ssh <host> .local/opt/agterm-headless/agtermctl session close --target <server id> --socket <server socket>`;
  `history` reads `session text --all` there. agterm-agents `c94d4f8`.

### Task 26: link clicks on a headless row

- [x] `agterm-open-link`'s `local_pane` reads a headless row as far, so a bare ref (`!12`, `#34`, a commit hash)
  answers "Remote pane: X not resolved". It now reads the checkout on the host in one ssh
  (`agterm-open-link --headless-git`), in the pane's live directory as Task 19 finds it. A hash found only on the
  host opens on the origin's forge. agterm-agents `3bc1fb9`.
- [x] Live check in `p4-live`: a file path, a Jira key, a full MR URL and a bare ref each open. On 2026-10-02 the
  path and the Jira key opened. The refs did nothing in any row: the Mac app was deployed from this branch, which
  lacked the Mac `main`'s `agterm-ref:` and `agterm-path:` support. Redeployed at 13:07 from a merge of both
  (`deploy-merge` in `~/tmp/headless-gate`); `github.view` set to `html`. After the restart the refs take the right
  path; the hash is unpushed and `#1` does not exist, so both answer "not found".

### Task 27: the attach picker and the scratch chord on a headless row

- [x] `agterm-attach-picker` lists a headless row as a Mac row with no daemon and a Mac cwd. It now lists on its
  host and attaches with `zmx attach <host> <server id> --transport ssh`. Its sidecar carries `headless_session`,
  and `agterm-row-origin` answers 2 for it until Task 22. agterm-agents `a36e073`.
- [x] `agterm-zmx scratch` opens on the host in `$HOME`; it now asks the host's `agterm-open-path --headless-cwd`
  for the pane's directory. agterm-agents `a36e073`.
- [x] Installed on p4linux and the Mac on 2026-10-02 (agterm-agents `main` `7cba0bb`). p4air was not reachable.

For Task 47: `agterm-open-path --headless-session` and `--headless-cwd`, and through them
`agterm-open-link --headless-git`, reach the server through the shim (`AGTERM_SOCKET`). Pass the server socket
through `ctl`'s `--socket` once `~/.local/bin/agtermctl` is the real CLI. `agterm-zmx`'s `headless_ctl` already
calls the server's own CLI. On a picked headless row the chat chord's refusal still says "attach it again from the
picker", which does not help; Task 22 replaces that path.

### Task 24: the split chord on a headless row splits on the origin

- [x] Measured on `p4-live`: a server split grows on the Mac and a server close removes it there. A Mac toggle only
  hides the view. A Mac close drops the Mac pane while the server's keeps running, and nothing on the server
  brings it back: only a new pane grows.
- [x] `agterm-zmx split [--close]`: on a headless row it splits and closes on the server; a Mac row that still shows
  the pane toggles it here; a pane only the server still has is refused with a banner pointing at the close chord,
  never killed unseen. Every other row gets the Mac toggle or close as before. agterm-agents `785382c`.
- [x] p4studio's `keymap.conf`: `cmd+ctrl+s` and `space>s` run "Toggle split", "Close split" runs `split --close`
  (backup `~/tmp/keymap.conf.before-split-chord`). Takes effect on Sasha's keymap reload.
- [ ] Later, outside this plan: the Mac's split verb itself forwards to the origin (the deferred ingress work), so the
  menu and the control API split on the origin too.

## Before the Phase 8 moves

- [x] Live check: mosh to a headless origin. On 2026-10-02 `zmx attach p4linux <p4-live id> --transport mosh` made
  a row that attached and showed the session as a mirror; closing it left the server session and its presenter.
- [ ] Not yet seen: a mosh row as the presenter, and one surviving a network change on the laptop. `zmx new` and
  `migrate` create ssh rows, so a moved row is ssh until it is re-attached over mosh from the picker.
- [ ] Install agterm-agents on p4air (not reachable on 2026-10-02): until then its scratch chord opens in `$HOME`
  on a headless row and its chat and split chords take the Mac-only path.

## Phase 8 moves, 2026-10-02/03

- Tasks 41 to 45 cherry-picked onto agterm-agents `main` and installed on p4linux and the Mac. The `offload.sh` merge
  took two peer fixes (`7b0a794`).
- Fixed before applying: the project slug (`db648e6`, `magnolia_main` rows looked unresumable); right panes follow
  their row as a server split instead of becoming orphan sessions (`b38a8e5`); `switch-rows` finds pins whose
  quotes are escaped (`1a521b8`); a name starting with `-` (`1faf803`).
- Moved: 113 left panes and their right panes into agterm-headless. On p4studio 56 rows present them; 3 pairs of
  rows pinned one key, so one row of each was switched and the other is left dead for Sasha to close.
- Not moved: `dev@p4linux-3` (blocked on a question), `arm-every-instance-2` (was active; an agent in its right
  pane), and the lead's own row (moved last, after this note).
- p4air holds rows of the 57 mapping lines p4studio skipped: run `agterm-headless-switch-rows --host p4linux` there
  once it is reachable.
- [x] Live step 4: `agterm-mac-path-check` with both Macs' trees lists only 4 dead p4air rows (offload peers
  from Sep 16 to 19 whose daemons died before the reboot; nothing runs in them).
- [x] Tasks 46 to 48 done on 2026-10-03: p4linux's `agtermctl` is the server's CLI (agterm-agents `67b1337`);
  the shim, the wrapper's shim branch, the legacy mosh tools and every `AGTERM_CTL_REMOTE_HOST` read are gone
  (`9f4b8e8`, `dbbaa8b`, merged on the Mac as `8aeaf61`); installed on p4linux, p4studio and p4air, the two
  retired launch agents unloaded on both Macs. Two test guards came with it: no XDG home and no live agterm
  reach a test.

## Order against Phase 8

1. Phases 1 to 3 here, each gated and live-checked. Before Phase 3's live check, Task 17 is
   cherry-picked onto agterm-agents `main`, with Sasha's approval.
2. Old plan live steps 1 to 4: move the rows, then `agterm-mac-path-check`.
3. Phase 8 Task 46's install: the real `agtermctl` on p4linux.
4. Phase 4 here.
5. Phase 5 here, before the moves of step 2 reach rows Sasha works in.
6. Phase 8 Task 47: remove the shim.

<!-- plan-review: planning:plan-review 2026-10-01 findings=51 resolved -->
