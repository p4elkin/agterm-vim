---
paths:
  - "agtermCore/Sources/agtermCore/OverlayRedirect.swift"
  - "agtermCore/Sources/agtermCore/Session.swift"
  - "agtermCore/Sources/agtermCore/Snapshot.swift"
  - "agtermCore/Sources/agtermCore/AppStore+Snapshot.swift"
  - "agtermCore/Sources/agtermCore/AppStore.swift"
  - "agtermCore/Sources/agtermCore/ControlProtocol.swift"
  - "agtermCore/Sources/agtermCore/ControlDispatcher.swift"
  - "agtermCore/Sources/agtermCore/BuiltinAction.swift"
  - "agtermCore/Sources/agtermctlKit/OverlayRedirectCommands.swift"
  - "agtermCore/Sources/agtermctlKit/SessionCommands.swift"
  - "agterm/Control/ControlServer.swift"
  - "agterm/Control/ControlServer+SessionActions.swift"
  - "agterm/Control/ControlServer+AppCommands.swift"
  - "agterm/Commands/OverlayRedirectController.swift"
  - "agterm/Commands/CustomCommandRunner.swift"
  - "agterm/AppActions+Palette.swift"
  - "agterm/Views/WindowContentView+Titlebar.swift"
  - "agterm/SettingsModel.swift"
  - "~/dev/agterm-agents/bin/agterm-zmx-mirror"
---

## Overlay redirect (fork only)

Every overlay Sasha opens (revdiff, lazygit, vifm, the fzf pickers) goes through one choke point,
`agtermctl session overlay open` → `ControlServer.openSessionOverlay`
(`agterm/Control/ControlServer+SessionActions.swift`). This feature makes that one function decide
which machine the overlay draws on when a laptop is mirroring a workstation session, or vice versa,
instead of always opening wherever the triggering `agtermctl` happened to run.

Design: `~/.claude/plans/2026-08-11-laptop-mirror-overlays.md`. The status HUD is a separate command
family (`sessionHudOpen`/`Update`/`Close`) and does not go through this choke point — left alone on
purpose, still appears on the workstation.

### The two pairing fields

Two new optional `Session` fields, both absent on every session that predates this feature:

- `mirrorsSession` (`OverlayMirrorSource`: host, session key, and that session's CWD on that host) — on
  the **laptop's** row. Which workstation session this row mirrors, and where it is sitting.
  `agterm-zmx-mirror` sets it when it creates the row and re-asserts it, cwd included, every pass.
- `viewer` (`OverlayViewer`: host, row key, `confirmedAt` epoch seconds) — on the **workstation's**
  session. Which laptop is watching. Set by the mirror job over the ssh connection it already holds
  open, refreshed on every 20-second pass.

⚠️ Neither field is derived by parsing `restoreCommand`, even though the laptop's own
`restoreCommand` already contains the host and key `mirrorsSession` duplicates. Both are written
through one explicit control command, `session.pairing` (mode `mirrors`/`viewer`), so the
workstation never has to infer that it is being watched — it is told. This also means clearing a
field is explicit (empty host string), not "stop finding it in a command string that changed."

⚠️ Both fields are OBSERVED (no `@ObservationIgnored`, unlike every neighbouring field on `Session`),
because the title-bar pill reads them inside a SwiftUI body. Ignoring them leaves the pill showing the
colour it had before the mirror job wrote the pairing.

⚠️ **A write that does not change the value must not `save()`.** `ControlServer.setOverlayPairing` skips
the store write when a `setViewer` moves only `confirmedAt`, and when a `setMirrors` re-asserts the same
source. The mirror job sends both on every 20-second pass for every mirrored row, and `store.save()` is the
undebounced full-snapshot write of the whole tree on the main actor. The in-memory field is what the
decision and the pill read; a restored `confirmedAt` is stale by definition anyway.

`viewer` goes stale after `OverlayRedirect.stalenessWindow` (40s, twice the mirror interval) compared
against a `now` passed into the decision function rather than read from a clock — a laptop that
closes its lid cannot clear its own field, so age is the only proof of liveness. A stale or absent
`viewer`/`mirrorsSession` both resolve to `.local`, the same as the toggle being off: this is how the
desk path (nobody watching) stays byte-for-byte what it was before this feature existed.

### The decision and the pill

`OverlayRedirect.swift` (host-free, `agtermCore`) is the one place the rule is written: toggle plus
the two fields plus `now` in, one of `.local` / `.mirrorOf(host:cwd:)` / `.watchedBy(host:row:)` out. The
pill's colour (grey/green/red) is derived from that same outcome (`OverlayRedirectOutcome.pill`), so
pill and behaviour cannot disagree — there is no second copy of the rule in the view layer.

The pill shows only while the toggle is ARMED. With the toggle off the answer is always "here", so a
permanent grey capsule would be chrome with nothing to say. ⚠️ This is also why the pill is deliberately
NOT an `InterfaceElement` and has no Settings toggle of its own (`SettingsModel.applyInterfaceElements()`
never sees it): it is already gated on the one setting that makes it mean anything. Do not add an
`InterfaceElement` case for it — that enum's count is pinned by tests and mirrored in the Settings UI.

⚠️ The pill is wrapped in a `TimelineView(.periodic(…by: 5))`. A `viewer` going stale is the passage of
time, not a state change, so without a clock nothing invalidates the body and red never turns back to grey.

The toggle is a keyless builtin action (`overlayRedirectToggle`), modelled on `normal_mode`.
⚠️ A keyless action needs `CustomCommandRunner.swift`'s `builtinSequences` merge
(`settings.keymap.binding(for: .overlayRedirectToggle)`) or a bound chord parses, resolves, and does
nothing — there is no menu item to dispatch it otherwise. `normal_mode` needed the identical line for
the identical reason; grep the surrounding block before adding a third keyless action rather than
rediscovering this.

### The two-phase protocol, and why it has two phases

`session.overlay.open` both decides and opens in one call. It cannot simply return the decision to
`agtermctl` and let a second, already-resolved call come back through the same path, because that
second call would re-enter the decision and loop:

1. `agtermctl` sends `session.overlay.open` as it does today.
2. The app runs the decision. `.local` opens and answers exactly as before this feature. Either
   redirect outcome opens **nothing** and answers with the outcome, the host, and the row id —  not
   even `--follow`, since the overlay is about to open on the other machine.
3. `agtermctl` builds the wrapped command and re-sends with `resolved` set. The app skips the
   decision entirely for a `resolved` request and opens plainly, targeting the id the phase-one
   answer already gave it (never re-resolving "active session", which could race a selection change
   between the two calls).

`resolved` is not user-facing and is hidden from `--help`.

⚠️ **`--resolved` crosses the ssh hop too**, not just the local re-send. In the watched-by direction the
remote `agtermctl session overlay open` carries it, because the viewer's row is ITSELF a mirrored row: its
own `mirrorsSession` would answer `mirror-of` and wrap the trigger in a second ssh — back to the machine
that just sent it, which would then have to ssh to itself. Without the flag the overlay still appears, but
every keystroke crosses two hops.

`session.overlay.open` is also where the working directory is decided. ⚠️ **The mirror-of arm sends a cwd
whether or not `--cwd` was passed** — none of the nine keymap chords passes one — and the one to trust is
the PAIRING's, `redirect.cwd`, which the mirror job read from the workstation's own tree.

⚠️ **A mirrored row's process directory is NOT the remote shell's**, though it looks like it should be.
libghostty drops the mosh shell's OSC 7 as not local, so the row keeps the `--cwd "$HOME"` the mirror job
pinned at creation, and the redirect's `cd` then lands in the workstation's `$HOME` — a path that exists
there, so the overlay opens happily in the wrong repository and says nothing. This exact belief ("its shell
IS the remote shell, so the process directory is already a workstation path") is what made two acceptance
runs fail; do not restore it. Order: an explicit `--cwd`, then the pairing's, then the process directory as
the last resort — and that last resort now prints a line to stderr, because it is the case where the wrong
directory is otherwise invisible.

The resolved re-send then drops cwd entirely: the path is baked into the remote half, and a far-side path
that does not exist here would fail the local overlay's own spawn.

⚠️ **The pairing's cwd is the PANE's, not the session's.** `tree`'s session node reports `effectiveCwd`,
always the primary pane's, and the mirror job makes one row per surface — so a mirrored `-right` row was
handed the LEFT pane's directory. `ControlSurfaceNode.cwd` (fork only, present only on `right`, omitted when
it is the session's) is what the mirror job reads instead.

**`--target/--window/--socket` apply only to the LOCAL fallback path.** Once the far side's row is found,
its id becomes the target, on whichever socket the remote host resolves by default. Consequence: if the
viewer machine runs agterm under a non-default `AGTERM_STATE_DIR`, a watched-by redirect targets the wrong
instance over there and the caller's own `--socket` is ignored on that leg. (Carried over from the retired
`bin/agterm-remote-overlay`, which had the same rule.)

### The ssh leg, ported from `bin/agterm-remote-overlay`

`bin/agterm-remote-overlay` (formerly in `~/dev/agterm-agents`, retired once `OverlayRedirectCommands
.swift` replaced it — see below) solved this feature's escaping chain first. The reasoning, since the
script itself is gone:

- **The ssh-back command is a file written on the target host, not a string handed to `session
  overlay open` inline.** That string already crosses one ssh hop and one internal agterm `sh -c
  eval` before anything runs, and the caller's own `<command>` must still see exactly ONE shell parse
  — the contract a plain local `session overlay open` already gives it. A file, written byte for byte
  with no shell re-parsing at write time, absorbs the two extra layers so `<command>` never sees more
  than the eval it already signed up for. The trigger sent over the wire then only ever needs to say
  "ssh back, then run this path": a host name and a generated `/tmp` path, both safe to single-quote.
- **`dq_escape`** (now `OverlayRedirectCommands.dqEscape`) is the same double-quote escaping
  `agterm-zmx`'s own quoting uses, applied because the value is nested one shell-eval deeper than
  plain text by the time it reaches its destination.
- **`--block` is carried, not reimplemented.** In the mirror-of case the overlay is local, so the
  existing block/poll loop runs untouched. In the watched-by case `agtermctl` passes `--block` to the
  *remote* `agtermctl` and inspects the ssh process's own exit status instead of exec'ing it — the
  script used `exec`, which this feature cannot: falling back to a local overlay on an unreachable
  far side is only possible if the process is still around to fall back with. The
  local poll loop must never run for a watched-by overlay, or it polls a session with no overlay on
  it and reports failure.
- **Which remote statuses mean "fall back", and why it depends on `--block`.** Without `--block` the
  remote `agtermctl` returns as soon as the OPEN is done, so ANY nonzero status there means the open
  failed — an older `agtermctl` over there, the row closed inside the staleness window, `--pane right` on
  a row that is not split — and the overlay must still appear somewhere, so it falls back locally. Under
  `--block` the status is the remote PROGRAM's own and has to pass through, so only ssh's reserved 255 can
  be read as "not reached". ⚠️ A remote program that genuinely exits 255 is indistinguishable from an ssh
  transport failure, and its command then runs a SECOND time, locally.
- **Every fallback says so on stderr.** A redirect that quietly does not happen is the failure mode this
  feature exists to remove, and the local overlay it falls back to looks exactly like a working one. When
  the ssh back could not have worked because of THIS machine's own name — an mDNS `.local` name, or a bare
  name with no dots, i.e. `hostname` with nothing configured — the message names the config file below
  rather than just reporting the failure.
- **A fallback clears the `viewer` pairing first** (`session.pairing` mode `viewer`, empty host). Nothing
  else would: `confirmedAt` keeps being refreshed by the mirror job's laptop→workstation leg, so if only
  the workstation→laptop direction is broken (different host key, agent, firewall) the pill would stay RED
  forever while every overlay quietly opened locally. Clearing turns it grey now and lets the next mirror
  pass re-arm it. A failure to WRITE the script is different — that is a local problem, so it prints to
  stderr and falls back without touching the pairing.
- **Every fallback deletes the script it wrote.** Only the script that really runs `rm -rf`s its own
  directory, so a redirect that never reached the viewer would otherwise leave one behind forever.
- ⚠️ **The script directory is under `NSTemporaryDirectory()`, never `/tmp`.** On macOS that is per-user
  (`/var/folders/…`) and still reachable by the same user over the ssh-back, so no other local account can
  pre-create the directory, plant a symlink at the script path, or swap the file between the write and the
  `sh <path>` that runs it. The random component is on the DIRECTORY (a fresh one per invocation, created
  with `withIntermediateDirectories: false` so an existing one is an error): two invocations sharing a
  directory would have the first script to finish delete the other's pending one.
- Every ssh carries `-o ConnectTimeout=2`, so an unreachable laptop costs two seconds, not a TCP
  timeout.
- The far side's `agtermctl` is named by absolute path, `/opt/homebrew/bin/agtermctl`, overridable with
  `$AGTERM_REMOTE_AGTERMCTL`. A non-interactive ssh lands with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, where
  a bare `agtermctl` reads as "command not found" (see the `p4machines` skill).

**What was deliberately not ported**, because the fork's registration-based discovery replaces the
need for the OTHER half of the retired script's discovery:

- The Tailscale self-lookup autodetect for "this machine's own name, as reachable from the other
  side." A written file is inspectable and does not depend on a CLI whose install location varies
  (App Store vs. brew vs. `/opt/homebrew`); see the config file below instead.

**The self-host config file, ported from the retired script's `read_config` and `resolve_source_host`**
(the discovery half — `host=`, finding the OTHER machine — was dropped; only "what do I call myself"
survives, because the fork's registration already tells each side who is watching):

Both machines read the SAME path, `~/.config/agterm-overlay-redirect.conf`, and
`$AGTERM_OVERLAY_REDIRECT_CONFIG` moves it on BOTH sides — pointing one half at another file is what makes
the two disagree.

⚠️ **The parsing rules are written out once**, in `OverlayRedirectSsh.readConfiguredSelfHost`'s doc comment,
and `agterm-zmx-mirror`'s `read_overlay_redirect_self_host` implements them character for character. Each
rule has a test on both sides (`OverlayRedirectSshTests`, `agterm-zmx-test`), because a divergence here is
invisible from either machine: one writes a name the other never ssh's to, and the redirect degrades to a
local overlay in silence. The rules, in short: `#` starts a comment even mid-line; blank lines and lines
with no `=` are skipped; key and value are trimmed of ALL whitespace, tabs and a CRLF's `\r` included; the
FIRST `self=` line wins and the read stops, empty value included; a missing file means "not configured".
Two of these were real divergences — the shell half concatenated every `self=` line, and dropped a last
line with no trailing newline, both of which put it back on the mDNS `hostname` fallback.

`OverlayRedirectSsh.resolveSourceHost` (Swift, `OverlayRedirectCommands.swift`) and
`mirror_self_host`/`read_overlay_redirect_self_host` (shell, `agterm-zmx-mirror`) both resolve this
host's own name in the SAME order, so a laptop or workstation only has to say who it is once:

1. `$AGTERM_OVERLAY_SOURCE_HOST` (then `$AGTERM_REMOTE_OVERLAY_SOURCE_HOST` on the Swift side only,
   so an existing `agterm-remote-overlay` env-var setup carries over)
2. the config file's `self=` line
3. `hostname` / `ProcessInfo.hostName`, trailing dot stripped — the LAN-only fallback, kept last so a
   single-machine user who configures nothing keeps today's behaviour exactly

⚠️ **Setup, and nothing ships written**: neither repository creates, seeds or validates this file, so
until it is written by hand the resolved source host is the bare `.local` mDNS name (e.g. `p4studio.local`),
which only resolves on the same LAN. A watched-by overlay attempted off-LAN then falls back to a local
overlay on the workstation — with a stderr line naming this file, which is the only reason the case is not
silent. Write `self=<tailscale-name>` into `~/.config/agterm-overlay-redirect.conf` on both machines (see
the `p4machines` skill for the Tailscale names) before relying on the watched-by case away from the LAN.

`bin/agterm-remote-overlay` was `git rm`'d from `~/dev/agterm-agents` once this section captured its
reasoning; `bin/agterm-zmx-retire` (a separate, unrelated script that retires the outside zprofile
wrapping hook) was not touched.

### The mirror job's side

`agterm-zmx-mirror` writes both pairings, and both writes are best-effort: a failure logs "an older
agtermctl" and never aborts `reconcile_once`.

- `register_mirrors_pairing` runs on the LAPTOP over its own local socket — for a row it just created, and
  again on every pass for a row that already exists. The re-assert is the BACKFILL: a row made before this
  feature, or one whose creation-time write hit an older `agtermctl`, would otherwise never get a pairing,
  since the viewer side self-heals every pass but this side would not. It is free because an unchanged
  `setMirrors` skips the save (above).
- `refresh_viewer_registrations` writes the WORKSTATION's `viewer` field, naming the far side's `agtermctl`
  by absolute path and honouring `$AGTERM_REMOTE_AGTERMCTL` exactly as the Swift half does, ⚠️ in **one** ssh carrying every
  row's write in a single remote shell, not one ssh per row. At `MIRROR_MAX`=12 a connection per row was
  twelve TCP+auth handshakes every twenty seconds, and a slow workstation could make the serial
  `ConnectTimeout=2` loop outrun `MIRROR_INTERVAL` itself. The writes are joined with `;`, so one the far
  side rejects does not skip the rest.

### Left out on purpose

- **The status HUD** and the two config-editing overlays (`agterm/AppActions.swift:351,378`) — see
  the design doc's "Left out on purpose" for why.
- **Two viewers at once.** One `viewer` field, no contention rule.
- **Pulling the laptop's attention** to a redirected overlay. `--follow` passes through unchanged;
  redirect does not decide it.
- **The documentation mirrors [[control-api]] requires for every command.** This branch adds two public
  `Command` cases and leaves `plugins/agterm/skills/agterm/`, `site/commands.html` and `README.md` at
  "75 commands" on purpose, `SkillInstallTests`'s pin included. Those files describe UPSTREAM agterm, which
  a user installs from Homebrew; a fork-only command in them would document something their `agtermctl`
  does not have. `.claude/rules/` is where the fork's own count lives.
- **No `InterfaceElement` case for the pill** — see "The decision and the pill" above.
- **No Settings UI for the toggle.** Chord, palette, and `agtermctl overlay-redirect toggle` only.
