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
attach a second client to the live one on the next Command-D, and re-attach the row to a fresh `-left`
after a restart. `ZmxWrap.Inputs.existingKey` is how the recorded key gets back into the decision; it is
refused unless it parses as a key of THAT session, so a copied snapshot cannot alias two rows onto one
daemon.

### Wrap decision

A pane is wrapped when ALL of these hold: its session is not isolated (no `AGTERM_STATE_DIR`); zmx is
installed on the widened PATH; the socket path is inside `ZmxSocketBudget`; and it has no pinned command
(would run a shell, not replace it). The wrap produces `zmx attach <key>` through
`CommandRestore.shellQuotedLine`.

Isolated instances never wrap. A row with a pinned command and `--keep-shell-open` wraps as
`zmx attach <key> <shell> -lc '<command>\nexec <shell> -l'`.

Every rejection is a normal outcome and is logged at `notice`, not `debug`: the whole failure mode of
this feature is unwrapping silently, so the reason has to be collected by default.

### Wrapper form

The wrapper is ALWAYS a bare `zmx attach <key>`, never `zmx attach <key> <command>`.
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

The command and the `exec` tail are separated by a NEWLINE, not `; ` — a pinned command ending in a `#`
comment would otherwise swallow the tail and the row would vanish exactly as it does without the flag.

⚠️ Open question: a restored keep-shell-open row hands that same `-lc` script to a zmx session that already
exists. `zmx attach <name> [command...]` is documented as "attach to session, creating if needed" with the
command used INSTEAD of creating a shell, which reads as create-time only — but nothing in code, tests or
the manual checklist confirms that a second attach with a command is a no-op. If it is not, such a row
re-runs its command inside the live session on every launch.

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
The idea it leaves open, if it ever becomes annoying: a PARKED session — an explicit "keep this daemon
without a row" claim the reaper honours, which is a claim-side feature and not a change to any close path.

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

### Reaping

The launch reap ends detached daemons nothing claims any more. Three constraints hold it back, and each
one is there because the failure mode is killing a live agent:

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
session still holds what was running. The factories therefore drop `plan.initialInput` and force
`waitAfterCommand` false for a wrapped pane, and turning `restoreRunningCommand` off is not required for
this feature.

### The inherited session scrub

An agterm launched from inside a wrapped pane inherits `ZMX_SESSION`, and libghostty spawns every surface
from the app's own environment, so `ZmxWrapping.scrubInheritedSession()` runs in `agtermApp.init` before
any surface exists. `ZMX_DIR` is deliberately NOT touched: the budget probe and every spawned `zmx` call
need whatever directory the user pinned.
