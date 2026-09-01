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

### Improved

- `tree` reports `sessionRecency`, the window's jump-back list with the active session dropped and the
  visible navigation scope applied
- `keymap list` reports the `nmap` binds in their own section, each carrying the mode word only when that
  word changes the outcome, and the cheat sheet shows it too
- the chrome pills moved from the title bar to the sidebar footer, and stay visible while terminal zoom
  hides the sidebar
