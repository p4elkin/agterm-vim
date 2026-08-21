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

### New Features

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
