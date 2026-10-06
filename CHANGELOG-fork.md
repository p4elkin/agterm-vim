# Changelog — the agterm fork

Release notes for this fork only. `CHANGELOG.md` beside it belongs to upstream `umputun/agterm` and is
taken whole on every rebase, so nothing written there survives; fork notes live here. `scripts/release.sh`
publishes a section from this file as the GitHub release body through `--notes-file`.

Was `CHANGELOG-vim.md` until 2026-08-21. The fork started as vim keybindings and has not been only that
for a long time, so the name was doing the same thing the old `FORK-NOTES.md` was — describing a fork that
no longer existed.

`FORK-NOTES.md` is the other half: this file is ordered by release and describes deltas, that one is
ordered by feature and describes the current state. ⚠️ A feature landing needs a line in both.

Entries describe what a user of the fork gets that upstream does not. Upstream's own changes for a given
version are in `CHANGELOG.md`.

Release sections are headed `## vX.Y.Z - YYYY-MM-DD` and go below this preamble, newest first.
`release.sh` matches that heading exactly and reads to the next `## `, so a section titled anything else
publishes an empty body with only a warning on stderr.

## Unreleased

### Changed

- Upstream's `Open links in` setting decides who opens a web link clicked in a pane. `Browser`, the default,
  keeps `agterm-open-link` and its Jira and merge request views; `Session overlay` shows every web link as a
  page over the session instead. File paths, forge refs and xchat links work the same under both.

### Fixed

- A Mac that wakes in the background no longer takes a headless row's presenter role from the Mac in use, and the
  origin drops a presenter that leaves a forwarded request unanswered, so opens and other forwarded commands stop
  failing with `the presenting Mac left` after the other laptop sleeps again.

### Added

- `agtermctl session overlay open --html <file>` works from a session on the headless origin. The
  server serves the file's folder (or `--cwd`) over HTTP on its Tailscale name, under a random token, and
  the presenting Mac loads it as a `--url` page, CSS and images included; reload re-reads the file.
  `install.sh` seeds `AGTERM_HEADLESS_PAGE_HOST` in `~/.config/agterm-headless/env` from Tailscale. The
  tailnet must reach port 19510. Unlike a local file page, a served page gets no theme defaults and no
  `--chromeless`.
- `--url` pages load plain http from `*.ts.net` hosts: agterm exempts the tailnet from App Transport
  Security, so a page served by a machine on the tailnet (plannotator, `--html` pages) loads away from the LAN.
- an agent offloaded on p4linux gets its Mac row again, right after the row that started it. On the
  headless origin `agtermctl zmx attach <host> <id> --beside <row>` asks the Mac presenting that row to
  attach the session, over the presentation stream that Mac already holds, so nothing calls the Mac.
  With no presenter the session waits in the picker, as before.

### Changed

- every agent on p4linux now runs in a session of its headless server. The old rows, a mosh attach of a
  zmx daemon on p4linux, were moved in with their conversations (agterm-agents `agterm-zmx-park migrate`
  and `agterm-headless-switch-rows`), and agterm-agents' `agtermctl` shim is removed: on the Linux host
  `agtermctl` is the server's own CLI. A new agent there is made with `agtermctl zmx new <host>`.
- the fork's own zmx pane wrapping is gone; upstream's is used instead. Upstream shipped native zmx
  wrapping of its own between `82d6f17` and `c8860a9`, and carrying both was not possible — the two
  implementations own the same seam in the surface factory and collide on three file names. Upstream's
  is the larger feature: it bundles and signs a pinned `zmx`, adds a Restore mode setting
  (`Fresh shells` / `Re-run commands` / `Live sessions`), replays commands into daemons recreated after a
  reboot, and exposes `agtermctl zmx list|prune|kill` plus `restore.mode` over the control socket.
  ⚠️ Three things change for anyone who used the fork's version. Wrapping now happens only in
  `Live sessions` restore mode, not for every pane. Daemons are named `agterm-<hex12>` from a per-pane
  identity, not `<session-uuid>-left|right`, so daemons detached under the old build are orphaned once.
  They live in a private `ZMX_DIR` (`/tmp/agterm-zmx-<hash of the state directory>`), so a plain shell,
  a mosh session or `agterm-zmx pick` reaches them only after exporting that directory —
  `agtermctl zmx list --json` names every daemon with its window, workspace, session and pane.
- `session new --keep-shell-open` is removed with the wrapper that implemented it. In `Live sessions`
  mode a fresh pane's command is typed into the daemon's login shell already, which is what the flag
  asked for; in the other two modes there is no shell to keep open.

### New Features

- `agtermctl session status <state> --note "<text>"` attaches a one-line reason to an agent status, so a
  row can say why it is blocked. It reads back as `statusNote` in `tree --json` and as `note` on the
  `status` event, on local rows and on rows mirrored from a headless origin. The next status set without
  it clears it; a change of the note alone does not move `statusChangedAt`.
- a bare file name printed in any pane is clickable: Shift+Cmd+click `links.conf` or `README.md:12` and it
  opens like a path with a directory. It is looked up in the pane's directory and repository first, then in
  the repositories open in other agterm rows, then in zoxide's most-used ones; several matches in one place
  open a chooser. Needs the same `links.conf` include as forge references.
- forge references printed in any pane are clickable. Shift+Cmd+click `!482`, `#12`, a commit hash such as
  `c865bc6c`, or `group/proj!12`, `group/proj#34` and `owner/repo@c865bc6c`: the MR, PR or issue opens over
  that pane, resolved against the pane's checkout and its `origin` on GitLab or GitHub. A commit always opens
  a plannotator review of its diff, from the local clone or fetched from the forge. GitLab issue, commit,
  pipeline and job URLs and GitHub pull request, issue and commit URLs open too: a pipeline as a job table per
  stage, a job as its log tail. A short ref in a remote pane is not resolved and says so in a HUD. Needs
  `agterm-open-link` from agterm-agents, `glab` and `gh` (logged in), `agterm-plannotate`, and one line in
  `ghostty.conf`: `config-file = ~/dev/agterm-agents/share/agterm-open-link/links.conf`
- a Jira key or a GitLab merge request URL printed in any pane is clickable. Shift+Cmd+click `MGNLPN-823` or
  an MR link and the issue or MR opens over that pane: summary, status, description and comments, in a
  terminal view by default, or as a rendered page or in the browser, chosen per kind in
  `~/.config/agterm/open-link.conf`. Every other web link opens the browser as before. Needs
  `agterm-open-link` from agterm-agents on `~/.local/bin`, `acli` and `glab` (logged in), `revdiffm` or
  `glow` for the terminal view, `cmark-gfm` for the page view, and a `link` rule in `ghostty.conf` for Jira keys
- a file path printed in any pane is clickable. Shift+Cmd+click `docs/plans/x.md` or `src/a.swift:12` and
  the file opens over that pane, markdown in plannotator and code in revdiff. The path is found even when
  it is relative to another directory: the pane's, the git root, the main checkout of a worktree, a
  matching suffix in the repo, then Spotlight. Several candidates open a picker; none shows a HUD that
  hides itself. A path in a pane running on p4linux opens the p4linux file, with the viewer running
  there. Needs `agterm-open-path` from agterm-agents on `~/.local/bin` on both machines
- `agterm-headless`, a server for a Linux host with no GUI, answers the real `agtermctl` over its own
  control socket. It serves `tree`, `window list`, `events read`, `version`, `zmx tree`, `zmx list`,
  `zmx present`, `zmx kill`, `notify`, `session new`, `session close`, `session rename`, `session split`,
  `session split close`, `session swap`, `session text`, `session hud open|update|close`, `ask`,
  `ask result`, `ask cancel`, `session status`, `context`, `seen` and `mark`,
  and refuses every other command with a reason that names it (no windows or UI, no terminal surface, a
  Mac feature, or a later phase). Each pane it creates, split panes included, runs in its own zmx daemon
  under the user's login shell, with its own `AGTERM_*` environment. Closing a session kills its daemons,
  and a pane whose daemon ends from outside closes within seconds. Every zmx call has a 5-second deadline,
  so a hung zmx no longer hangs the server. `scripts/headless/install.sh` builds and installs it with its
  own zmx and runs it as a systemd user service that restarts without ending any session;
  `scripts/headless/check-version.sh` says whether each Mac can follow it. A HUD or a terminal ask opened
  there appears on the Mac viewing that session; an ask opened with no Mac viewing waits and appears when
  one connects. In progress; Linux only.
- `agtermctl session type` works in a session on the Linux origin, written into its zmx daemon with `zmx type`, so room
  delivery and the compact tools reach it even when no Mac is attached.
- in a session on the Linux origin, `agtermctl pick`, `session flag`, `session focus`, `session search`,
  bookmarks, `session overlay open --url` and the other commands that need a window now run on the Mac
  presenting that session instead of being refused. They name the session with
  `--target "$AGTERM_SESSION_ID"`, which `pick` does by itself, and fail with `no Mac is presenting this
  session` when no Mac is.
- a program overlay opened in a session on the Linux origin (`session overlay open <command>`, so revdiff and
  `agterm-open-at` too) shows on the Mac presenting that session while the program runs on Linux, in the
  session's directory and environment; `result` and `--block` report its exit code. The Linux host's
  `agtermctl` must reach the server: its own CLI, which agterm-agents links in.
- when the Mac presenting a remote session disconnects, another Mac viewing it now takes over as
  presenter, and an ask shown on the first moves to it with its id and pane.
- `agtermctl zmx new <host> [--name] [--command] [--cwd] [--window]` creates a session on another
  machine's origin and attaches it here in one step. A split opened on the origin while you watch now
  appears on the Mac instead of needing the row closed and attached again. The Mac whose pane takes the
  lead also takes the presenter role, so asks, HUDs and overlays follow the Mac you are typing on.
- opening a remote row on the Mac now clears its unseen count and an auto-reset status on the origin
  too, so a reattach, a second Mac or a server restart no longer shows them again.
- remote rows survive a relaunch: each comes back in its window, workspace and place, in every restore
  mode. A row whose connection dropped says "Disconnected from <host>, retrying" and reattaches by itself
  within 30 seconds of the host answering; one whose session ended there says "Ended on <host>. Close the
  row to remove it". `tree` reads this back as `remoteState`.

- a pane pinned with `--keep-shell-open` now starts ONE login shell instead of two. The command is typed
  into the login shell zmx spawns for the session rather than wrapped in another `zsh -lc` that has to
  `exec` a third. Nothing is resident either way, but the saved profile load is paid per pane at surface
  creation, and after a reboot every parked row pays it at once. A bare command name also resolves now,
  because it runs on the login PATH. ⚠️ Behaviour change: a RESTORED keep-shell-open row no longer re-runs
  its command — it comes back at a prompt. That is deliberate. Its zmx session is normally still holding
  what was running, and typing there would run the command a second time inside the live program; when the
  session is gone, after a reboot, the row comes back empty instead of spawning a fresh agent. The previous
  form did spawn one: measured on 2026-08-30, 41 of 88 parked rows came back with a new Claude in them,
  7.9 GB resident
- bookmark a turn in an agent conversation and jump back to it. The agent prints a numbered mark at the
  start of each turn, `session bookmark add` records that number plus the prompt text, and
  `session bookmark go` searches the pane for the mark. `session.search` is the only thing that moves a
  pane's viewport and it matches visible text, so a bookmark stores something findable rather than a
  position — a number being unique where a prompt-text search is not. The agent has to be the one printing
  it: every layer that owns a screen repaints it from its own buffer, so a mark injected into a pty from
  outside is wiped before the next frame and never reaches scrollback. `session mark` therefore just
  counts, and the hook hands the number to the agent to echo. Browsing is an overlay running fzf over
  `bookmark list --all`, not app UI. A bookmark whose mark has left scrollback still lists and shows its
  prompt; only the jump is lost
- an attention-counts pill beside the other chrome pills: how many sessions are blocked, working and
  finished, plus the current session's unread count, each a distinct glyph in its configured status
  colour. It answers what the title-bar bell cannot — how much, and of what kind — and appears
  bottom-right over the terminal exactly when the sidebar is not on screen. A zero category draws nothing
  and a quiet window draws no pill. The unseen segment is gated on the notification-badge setting, like
  the sidebar and Dock badges; the status segments are not. Informational, never clickable
- a cross-agent message id printed in any pane is clickable. Shift+Cmd+click a `msg-…` id and the parked
  message opens in an overlay over that pane. It rests on a new `link = <action>,<regex>` config key, which
  upstream ghostty declares but cannot parse, so the fork carries its own parser plus an `open:<template>`
  action that turns a match into a URL. The id resolves through agterm's own `agterm-xchat:` scheme, which
  is answered in-process and never handed to the system opener. ⚠️ Shift is required, not optional:
  ghostty disables link hovering while an application has mouse reporting on, and shift is the one escape
  it leaves — this applies to plain URLs in agterm too
- a modal vim-style normal mode with its own `nmap` keybind namespace, entered from a `map <chord>
  normal_mode` line the user writes. Built-in actions fire from keymap leader sequences, an `nmap` target
  may name a custom command, and a line may end in an optional `insert` or `normal` mode word that decides
  whether firing it leaves the mode. Esc leaves the mode and hands an Escape keypress down to the pane, so
  vim or a shell in vi-mode enters its own normal mode from the same press
- the mode yields the keyboard to a program overlay that appears under the user and takes it back when the
  overlay quits, while walking onto a session whose overlay is already running keeps the keys, so `j`/`k`
  carry past it
- `new_session_in_workspace` opens a picker of the workspaces and creates the new session in the one you
  choose, selected and focused. Typing a name no workspace has offers a `Create workspace "<name>"` row
  below any workspaces still matching. It ships keyless: bind it with `nmap space>n>w
  new_session_in_workspace` or a `map` line
- panes are wrapped through zmx, so a pane's shell survives the app and can be reattached. Session keys are
  derived per pane, orphaned daemons are reaped at launch, a wrapped pane's foreground process resolves
  past the zmx client, and `session new --keep-shell-open` leaves the row at a prompt after its command
  exits instead of losing its only process
- an overlay opens on the machine the user is actually watching from, so an overlay fired on the
  workstation appears on the laptop that is mirroring it
- a recency dwell threshold: a session joins the Ctrl-Tab jump-back order only once you have stayed on it
  past the threshold, or typed in it, so walking through the sidebar no longer buries the session you were
  actually working in. An absent setting means 20 seconds, not zero, and `immediate` restores the old
  behaviour for anyone who dislikes it
- hidden surfaces release their GPU resources, opt-in, with unrealize debounced and surfaces born hidden
  covered
- `zmx attach` takes `--transport ssh|mosh`, `--mosh-server PATH` and `--mosh PATH`, so a remote
  session can attach over mosh and survive laptop sleep and roaming while ssh stays the default.
  `--mosh-server` names the far-side `mosh-server`; it is optional, and omitted the far side uses its own
  lookup, but a Homebrew one needs it, because mosh's ssh bootstrap is a non-login shell and
  `/opt/homebrew/bin` is off its PATH. `--mosh` names the local mosh binary for an install outside
  `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`; agterm probes those three itself, so the attach
  works in a GUI-launched pane whose PATH lacks `/opt/homebrew/bin` too. Both are refused without
  `--transport mosh` rather than silently ignored. ⚠️ Under mosh the exit line's status is mosh-client's,
  not the guard's, so `disconnected, exit 0` after a vanished daemon is expected there
- `session split on --command <cmd> [--wait]` runs a command in a fresh split in the same step, as
  `session new --command` does, so a scripted remote row needs no second type call. `on` must be spelled
  out, because the mode default is `toggle`. An existing split, hidden or shown, is refused with
  `split already running; session split close first`, and the command persists in the snapshot and
  re-runs on restore in Re-run commands mode. ⚠️ `--wait` adds no hold on a local row in Live sessions
  mode: the zmx-wrapped split runs the command and falls through to a login shell; only
  ordinary/fallback and remote-host sessions hold

### Improved

- `zmx list` names the socket directory the daemons live in, both in the plain listing's header and as
  `socketDirectory` in `--json`. A script attaching from outside the app exports that value as `ZMX_DIR`
  instead of reimplementing the hash of the state directory, and it reads the directory the app is
  actually using rather than one it guessed
- `tree` reports `sessionRecency`, the window's jump-back list with the active session dropped and the
  visible navigation scope applied
- `keymap list` reports the `nmap` binds in their own section, each carrying the mode word only when that
  word changes the outcome, and the cheat sheet shows it too
- the chrome pills moved from the title bar to the sidebar footer, and stay visible while terminal zoom
  hides the sidebar

### Fixed

- normal mode yields the keyboard to an HTML or URL overlay the way it does to a program overlay, so its
  bare-key binds no longer take keys meant for the page. Upstream's new page overlays stopped counting as
  a program overlay, which the yield asked.
- `session overlay open --pane` no longer loses runs to an empty command (3 of 10 measured). A pane
  overlay host SwiftUI mounted after the previous overlay closed built a surface running `""`, which exited
  0 and closed the next overlay on that pane before its program started, so `overlay result --pane`
  reported `exit 0` for a command that never ran. Each open now gets its own host generation, a pane with
  no overlay builds no program, and a surface left in an empty slot is freed on the next open or close.
- shells in agterm can reach the local network again after a rebuild. `make deploy` now signs the app,
  `agterm-session-host`, `agtermctl` and `zmx` with a local self-signed certificate and fixed identifiers,
  so the Local Network permission is not lost on every build. Without the certificate the build is
  ad-hoc signed as before; `.claude/rules/release.md` has the one-time setup.
- `tree` and `window list` no longer stall the app for 3 seconds per call once four Live daemons exist.
  `ZmxClient.run` read the child's output only after it exited; zmx writes the listing row by row, so the
  pipe never grows past its initial 512 bytes, zmx blocked on write, the app blocked on exit, and every call
  ended in the timeout with the Live leader snapshot dropped. Each pipe is now drained on its own thread
  while waiting, the fds are close-on-exec so a surface command libghostty spawns meanwhile cannot inherit
  a pipe end and hold EOF back for its lifetime (which hung the same call forever), and a listing whose EOF
  still never comes fails instead of coming back short. Upstream code since `d01a774`, on every `tree`
  since `4ec4d4b` (#574); reported as umputun/agterm#623, fix proposed in umputun/agterm#624
