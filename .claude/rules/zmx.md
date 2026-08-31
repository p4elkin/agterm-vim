---
paths:
  - "agtermCore/Sources/agtermCore/ZmxSessionKey.swift"
  - "agtermCore/Sources/agtermCore/ZmxSocketBudget.swift"
  - "agtermCore/Sources/agtermCore/ZmxListParser.swift"
  - "agtermCore/Sources/agtermCore/ZmxWrap.swift"
  - "agtermCore/Sources/agtermCore/ZmxLifecycle.swift"
  - "agtermCore/Sources/agtermCore/ZmxReaper.swift"
  - "agtermCore/Sources/agtermCore/ZmxForegroundSelection.swift"
  - "agterm/Ghostty/ZmxClient.swift"
  - "agterm/Ghostty/ZmxForegroundResolver.swift"
  - "agterm/Ghostty/ForegroundProcess.swift"
  - "agterm/agtermApp.swift"
  - "agterm/AppDelegate.swift"
  - "agtermCore/Sources/agtermCore/AppStore.swift"
  - "agtermCore/Sources/agtermCore/AppStore+Panes.swift"
  - "agtermCore/Sources/agtermCore/AppStore+PendingClose.swift"
  - "agtermCore/Sources/agtermCore/AppStore+Naming.swift"
  - "agtermCore/Sources/agtermCore/WindowLibrary.swift"
---

## Native zmx wrapping (fork only)

This feature is part of an internal fork and is not offered upstream. It moves the zmx wrapping that
was previously driven by a zprofile hook inside agterm itself. Every plain interactive pane is
wrapped with `zmx attach <key>` so the app knows which zmx session owns it, enabling accurate
foreground reporting and correct session cleanup.

### Known caveats

Behaviour that is surprising, deliberate, and will not be fixed by accident. Each one is argued where it
is implemented; this list exists so nobody has to read the whole file to find out what bites.

- **A promoted row's second pane is never zmx-backed again.** Close the left pane of a split and the
  survivor keeps `-right` for good, so the next Command-D would derive a key its sibling already holds.
  That pane is left as a plain login shell instead. See "Which key a pane owns".
- **A runtime attach failure closes the row.** The old zprofile hook fell through to a normal shell on a
  failed `zmx attach`; the wrapper cannot, because the fall-through shell would become the pane's
  foreground group leader and break every wrapper detection. See "Wrapper form".
- **Detach, close the row, come back after a relaunch, and the session is gone.** Nothing claims a daemon
  whose row left the snapshot, so the launch reap ends it. Accepted 2026-08-11; the unrowed-daemon-claim
  idea in "Lifecycle traps" is the way out if it ever matters.
- **A row with an automatic name keeps the label from its last surface build.** Only an explicit rename
  relabels; following the cwd would spawn a `zmx set` per OSC report.
- **A restored keep-shell-open row comes back at a PROMPT, never re-running its command.** Its command is
  typed only when the row is fresh, so after a reboot — which ends the zmx server and loses every session —
  the row attaches to a newly created shell and sits there empty. That is the deliberate price of never
  typing into a live agent. See "Keep-shell-open form".
  The old `zmx attach <key> <shell> -lc '<command>\nexec <shell> -l'` form did the opposite and it was
  measured on 2026-08-30: after a reboot 41 of 88 parked rows came back with a fresh Claude in them, 7.9 GB
  resident, from launchers that had last run days earlier. `agterm-park boot` in `~/dev/agterm-agents`
  existed to repair that once per login; the typed form removes the cause.

### Session key convention

Session keys follow `<session-uuid>-<role>` where role is `left` or `right`.
This differs from upstream's `agterm-<hex12>` scheme. Keeping the existing convention means old
daemons are adopted rather than duplicated, and existing tooling that parses this shape remains
compatible. Keys surface in `zmx list`, the pick list, mosh incantations, and remote scripts.

`ZmxSessionKey.Role` has only those two cases, because only those two panes are persistent rows.
`isOwned` additionally accepts the legacy `scratch` and `overlay` suffixes so the reaper can end a
daemon the outside tooling left behind, but `key` never produces one and the budget never reserves
room for one.
⚠️ `isOwned` requires the uuid prefix to match `uuidString` byte for byte. `UUID(uuidString:)` is
case-insensitive, so a lowercase-uuid name would read as owned yet never appear in
`ZmxReaper.claimedKeys` — an unclaimable name the reaper would kill on sight.

### Which key a pane owns

⚠️ A pane's key is RECORDED, never re-derived. The surface factory writes the key it wrapped with into
`Session.zmxPrimaryKey` / `Session.zmxSplitKey`, both persisted in `SessionSnapshot`; close, rename and
the next launch's wrapper all read it back from there.

The reason is `closePrimaryPane`. It promotes the split survivor into the main slot, and that survivor
stays the client of the `-right` session it attached to while the model calls it the main pane. Deriving
`-left` from "this is the main pane" would kill the wrong daemon on close, label the wrong one on rename,
and re-attach the row to a fresh `-left` after a restart. `ZmxWrap.Inputs.existingKey` is how the recorded
key gets back into the decision; it is refused unless it parses as a key of THAT session, so a copied
snapshot cannot alias two rows onto one daemon.

⚠️ Recording alone does not stop the DERIVED key of one pane from landing on the RECORDED key of the other.
A promoted row holds `-right` in the main slot with `zmxSplitKey` nil, so the next Command-D derives
`-right` again — two panes driving one terminal, and an `exit` in either ending the agent in both.
`ZmxWrap.Inputs.siblingKey` closes that: a pane is left UNWRAPPED, with a plain login shell, rather than
take the key its sibling holds. The check covers the adopted key too, so a snapshot that already carries
the collision cannot bring it back. `Session.zmxKeys(for:)` is the one place that says which key is a
pane's own and which is its sibling's, so a factory cannot swap them.

The cost is deliberate: a promoted row's second pane is never zmx-backed again, because its main pane keeps
`-right` for good. A plain shell there is the same safe outcome every other rejection produces, and the
alternative — handing the new split the free `-left` — can drop the user into the daemon the exited primary
detached from, where a later `exit` destroys the agent in it.

That exited primary's own `-left` daemon is left running on purpose. Its client going away may have been a
DETACH (`ZmxLifecycle.Close.clientExit`), so nothing may kill it. It stays claimed while the row exists,
because the claim covers both role keys of every persisted session, and it is reaped at the first launch
after that row is closed — the same end-of-life as any other detached session whose row is gone.

### Wrap decision

A pane is wrapped when ALL of these hold: its session is not isolated (no `AGTERM_STATE_DIR`);
`AGTERM_ZMX_SKIP` is unset or empty; zmx is installed on the widened PATH; the socket path is inside
`ZmxSocketBudget`; and it has no pinned command (would run a shell, not replace it). The wrap produces
`zmx attach <key>` through `CommandRestore.shellQuotedLine`.

⚠️ `AGTERM_ZMX_SKIP` is honoured HERE, not only by the zprofile hook, and that is load-bearing rather than
tidy. It is the documented escape hatch for a pane that should stay plain, the hook that used to read it is
being retired, and `agtermUITests` sets it in `launchForUITest` to keep a test pane off the multiplexer. Had
the wrapper ignored it, setting it would have gone on looking correct while the app wrapped the pane anyway.

Isolated instances never wrap. A row with a pinned command and `--keep-shell-open` wraps BARE like every
other row and gets its command back as typed input — see "Keep-shell-open form".

Every rejection is a normal outcome and is logged at `notice`, not `debug`: the whole failure mode of
this feature is unwrapping silently, so the reason has to be collected by default.

### Wrapper form

The wrapper is ALWAYS a bare `zmx attach <key>`, for every row, never `zmx attach <key> <command>`.
zmx's own help states that a provided command is used INSTEAD of creating a shell.
Folding a command inside would make that command the zmx session's entire process, not a program
inside its shell. That is exactly the vanishing agent row bug: claude exits, the session ends
because its only process is gone, the client exits and the pane has no process at all.

⚠️ A runtime attach failure is NOT survivable in the pane: the client exits and the row closes, where
the old `~/.zprofile` hook's `zmx attach "$key" && exit` fell through to a normal shell. What the row
close no longer does is destroy the session the attach could not reach — see the client-exit rule below.

### Keep-shell-open form

`--keep-shell-open` sets the flag on a row with an initial command and causes that command to run
inside the persistent zmx session's shell. After the command exits, the pane lands at a prompt
inside the same session, instead of exiting.
This differs from `--wait`, which holds the surface with a press-any-key prompt and then closes it.
Both address the same user pain and cannot both apply to one row; the dispatcher rejects the
combination. Store this flag on the session for both tree read-back and wrap decisions.

**The command is TYPED, not wrapped.** The wrap line stays a bare `zmx attach <key>`, and
`ZmxWrap.Decision.wrap` carries the command back as `initialInput`, which the factory hands to libghostty
as `initial_input` — the same "as if typed" path restore-running-command uses. zmx spawns a login `$SHELL`
for the session it creates, so the command runs in THAT shell.

Two things this buys, and they are the reason the older `zmx attach <key> <shell> -lc '<command>\nexec
<shell> -l'` form is gone:

- **One login shell per pane instead of two.** The old form loaded the full `~/.zshrc` in the `-lc` shell
  and again in the `exec`ed one. Startup cost only — the first shell `exec`s away and only the second is
  resident — but after a reboot 85 rows paid it at once.
- **The login PATH.** A pinned command is often a bare binary name, from `session new --command`, from a
  `cookbook/` recipe, or captured by restore off a live pane. Typing it into a login shell finds it; a
  plain `-c` shell would not, and the row would come back empty with nothing to say why.

⚠️ **Only a FRESH row types it.** `ZmxWrap.Inputs.sessionWasRestored` is `Session.wasRestored`, and a
restored row types nothing: its session is still holding what was running, and the keystrokes would land in
whatever program has the foreground. This is the same reasoning that already drops `plan.initialInput` for a
wrapped pane, extended to the pinned command. A fresh row cannot collide with a live daemon — its key comes
from a new session uuid, and `existingKey` is nil.
The cost is the reboot case in "Known caveats": the session is gone, the attach creates a bare one, and the
row comes back at a prompt.

⚠️ `initial_input` alongside a `command` is normally refused in `GhosttySurfaceView.createSurface`, because
a command REPLACES the shell and typed text would land inside that program. The wrapped pane is the one
exemption, passed explicitly as `commandForwardsInput`: `zmx attach` is a client that forwards keystrokes to
a shell of its own. Measured 2026-08-31 under a pty: input written at attach time survives zmx switching the
pane to raw mode and reaches the new session's shell.

The old form's `#`-comment trap is gone with the `exec` tail it protected — a typed line has no tail to
swallow — but the trailing newline still matters, because it is what submits the line.

### Isolated instance bypass

When `AGTERM_STATE_DIR` is set, three things are turned off: wrapping (panes run plain shells),
reaping (the launcher does not kill orphaned sessions), and the zmx close/rename sink
(row closes and renames send no zmx commands). This eliminates the cross-instance danger of an
isolated test run killing the deployed app's detached daemons.

### Socket path budget

A unix socket path caps near 104 bytes, so `ZmxSocketBudget.probe` refuses to wrap when the socket
directory plus the key would exceed 101 bytes, and the pane falls back to a plain shell.
⚠️ The live setup has TWO spare bytes: a 56-byte `$TMPDIR/zmx-<uid>` plus a separator plus a 42-byte key
is 99 against a 101-byte budget.
Three more bytes anywhere — a longer `TMPDIR`, a longer role name, a larger safety margin — silently
unwraps every pane.
`ZmxSocketBudgetTests.realSetupIsUnderBudget` pins that pair so the change fails a test instead.
The budget takes `ZmxSessionKey.maxByteCount` rather than a number written down beside it, so a role
added later fails that test instead of eating the margin.

### Lifecycle traps

⚠️ A pane's own EXIT ends NO zmx session (`ZmxLifecycle.Close.clientExit`). Under wrapping the pane's
process IS the zmx client, and a client exits for two reasons the app cannot tell apart: the session
ended, so there is nothing left to kill, or the user DETACHED from it, where killing would destroy the
agent they detached to keep. `closePrimaryPane` and `closeSplitPane` therefore pass `endingZmx: false`
into `closeSession`/`closeSplit`. The daemon a detach leaves behind is reattachable by name; an
abandoned one is reaped at the next launch.

That reap ends a detached session whose row was then closed, because the row is gone from the snapshot
and nothing claims the daemon any more. This is ACCEPTED, decided 2026-08-11: within one launch a detach
is safe, and losing the session on the next launch is the price of never killing a live agent on exit.
Do not add a workaround for it in the reaper.
The idea it leaves open, if it ever becomes annoying: an UNROWED DAEMON CLAIM — an explicit "keep this
daemon without a row" claim the reaper honours, which is a claim-side feature and not a change to any close
path. This is not `session.park`, which is the opposite shape: a ROW whose agent is gone. Nothing in
`ZmxReaper` reads `Session.parked`.

A closed WINDOW keeps its session ids persisted under `~/Library/Application Support/agterm/windows/`
and does not end any zmx session, because the window reopens with them. A closed window is not
a closed row. A DELETED window (`window.delete`) is: `WindowLibrary.removeWindow` destroys its rows for
good and ends their keys, taken from the live store when open and from the persisted snapshot when not.

The GUI close path is soft close followed by a grace period, then `hardFinalizePendingSession`
(not `closeSession`). This trap also applies to workspace closes routed through pending cleanup.

⚠️ The close/rename sink hands `zmx kill`/`zmx set` to a background queue so a timing-out zmx cannot hold
the main actor. At ⌘Q that means a row closed moments earlier can lose the race with the app's own exit and
leave its daemon behind until the next launch's reap. Accepted: a two-second main-actor stall on every close
is the alternative, and a leaked daemon is the recoverable side.

Rename has no zmx counterpart — zmx has no rename command — so a renamed row writes its display name
into each owned session's `agterm_name` label instead, which is what keeps `zmx list` and the pick list
readable.

A label is NOT a rename-only effect. `AppStore.recordZmxSession` both records the key and labels the
daemon, so every wrapped pane is labelled when its surface is built and again at each launch, and the
retired `dev.sasha.agterm-zmx-sync` is not needed to keep `zmx list` readable.
⚠️ That first label races the pane's own `zmx attach`: `zmx set` on a session that does not exist yet exits
1, so `ZmxClient` retries the call (`labelAttempts` times, `labelRetryInterval` apart) and stops at the
first success. A rename therefore still costs exactly one call.
What this does not cover is a row whose AUTOMATIC display name later follows its cwd: only a surface build
or a rename writes the label, so the daemon keeps the name the row had when its pane was built.

### Reaping

The launch reap ends detached daemons nothing claims any more. Three constraints hold it back, and each
one is there because the failure mode is killing a live agent:

- the claim covers keys a row does not own but MENTIONS. `agterm-zmx pick` binds a row to another row's
  key through its command, and that row is a `--command` row, so it is unwrapped and records no key of its
  own. ⚠️ `ZmxReaper.persistedClaim` therefore scans each window file's raw text for owned key shapes on top
  of the ids it derives keys from. Without it the picked daemon is unclaimed, zero-client at launch, and
  killed with the detached agent inside it. Scanning the text rather than named fields is deliberate: a
  field added later is covered without anyone remembering to list it.
- the claim comes from the snapshots persisted under `windows/`, NEVER from live windows. Restoration is
  asynchronous and a restored pane is zero-client until its client attaches, so `AppDelegate` runs the
  reap BEFORE `scheduleRestoredWindowReconciliation`. ⚠️ Moving that call later leaves every test green
  while killing the agents of windows that have not come back yet.
- an unknown client count is never an orphan; only an exact zero is.
- a nil answer from `ZmxReaper.persistedSnapshots` — a missing or unreadable `windows/` directory, or any
  file that does not decode as a current snapshot — skips the reap entirely rather than treating the
  claim as empty. An `windows/` directory that exists and is EMPTY is a real empty claim, so every owned
  zero-client daemon on the machine is then reapable.

### Foreground resolution past the wrapper

When `tree --json` is run, `ForegroundProcess.running` compares the pane's foreground argv against the
key that pane RECORDED. On a match it reads the zmx session listing, takes the session leader's pid, and
inspects that pid's controlling-terminal foreground group (`kinfo_proc.kp_eproc.e_tpgid`, which is
`tcgetpgrp` for a pty this process holds no descriptor for) instead of the wrapper's. This reports the
real running program. Matching the pane's own key rather than the key SHAPE is what keeps a session the
user picked by hand — `agterm-zmx pick` binds a row with the same shape — reported as the zmx client it
really is. The restore capture (`ForegroundProcess.command`) applies the same comparison in reverse: it
drops the pane's own wrapper so a restore never re-runs `zmx attach`, and keeps a picked binding.

A wrapper detection is a pure argv check with no subprocess. The listing is cached for one tree build and
run at most once per tree command, even with many wrapped panes, and it uses
`ZmxClient.mainActorBounded`, whose `zmx list` timeout is a fraction of the background one because
`buildTree` runs on the main actor and agent hooks call `tree` constantly.

Because the capture drops the wrapper, a wrapped pane needs no restore replay at all: the persistent
session still holds what was running. The factories therefore take the wrapper's own input decision over
`plan.initialInput` — nil for every wrapped pane except a fresh keep-shell-open row — and force
`waitAfterCommand` false, and turning `restoreRunningCommand` off is not required for this feature.

### The inherited session scrub

An agterm launched from inside a wrapped pane inherits `ZMX_SESSION`, and libghostty spawns every surface
from the app's own environment, so `ZmxWrapping.scrubInheritedSession()` runs in `agtermApp.init` before
any surface exists. `ZMX_DIR` is deliberately NOT touched: the budget probe and every spawned `zmx` call
need whatever directory the user pinned.
