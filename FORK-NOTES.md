# What this build adds over upstream agterm

This is a build of [umputun/agterm](https://github.com/umputun/agterm). Everything upstream does, it
still does, and every addition is opt-in — with an untouched `keymap.conf` the key path is byte-for-byte
what upstream ships, and a test pins that
(`ControlKeymapTests.untouchedKeymapProjectsExactlyTheShippedDefaultForEveryAction`).

Forked at `eb29d55`, and kept current by MERGING `upstream/master` in, never by rebasing onto it.
`git log` shows merge commits, so this file, not the log, is the answer to "what does the fork add".

This file is the CATALOG: what the fork has, and where each piece is written up properly. It is not a
changelog — `CHANGELOG-vim.md` holds the release notes, ordered by release and describing deltas. This one
is ordered by feature and describes the current state. ⚠️ When you add a feature to the fork, add a line
here as well as an entry there. The catalog went stale once already: the file said "two separable features"
long after there were nine.

## What's here

**Keyboard**

- **Leader sequences for built-in actions** — `map ctrl+space>s toggle_split`. Upstream allows one chord
  per action; this allows a sequence. Detail below, design in `.claude/rules/keymap.md`.
- **A modal normal mode** — the `normal_mode` action and the `nmap` verb, with bare keys, a mode word per
  line, and a pill in the titlebar. Detail below. Ready-to-copy preset in `cookbook/vim-keys/`.
- **`new_session_in_workspace`** — a picker of the workspaces, creating the session in the one you choose,
  with a `Create workspace "<name>"` row for a name none of them has. Ships keyless.
  `.claude/rules/menu-actions.md`.

**Panes and sessions**

- **Panes wrapped through zmx** — a pane's shell outlives the app and can be reattached. Session keys per
  pane, orphaned daemons reaped at launch, the foreground process resolved past the zmx client, and
  `session new --keep-shell-open` leaving the row at a prompt after its command exits.
  `.claude/rules/zmx.md`.
- **Overlay redirect** — an overlay opens on the machine you are actually watching from, so one fired on
  the workstation appears on the laptop mirroring it. `.claude/rules/overlay-redirect.md`.
- **A recency dwell threshold** — a session only joins the Ctrl-Tab order once you have stayed on it past
  the threshold, or typed in it, so walking past rows no longer buries the real work.
  `.claude/rules/settings.md`.
- **The chrome pills in the sidebar footer** rather than the title bar, staying visible while terminal
  zoom hides the sidebar.

**libghostty**

Both of these need a patch under `patches/ghostty/`, applied by `scripts/setup.sh` at `GHOSTTY_REV`.
Read `patches/ghostty/README.md` before touching either; when the pin moves, `git apply` fails loudly.

- **Hidden surfaces release their GPU resources**, opt-in, with unrealize debounced and surfaces born
  hidden covered. `0001-surface-realize-api.patch`. Measured before it: 129 surfaces holding 6.9 GB.
- **Clickable cross-agent message ids** — Shift+Cmd+click a `msg-…` id in any pane and the parked message
  opens in an overlay over it. Needs `0002-link-config.patch`, which implements the `link` config key
  upstream declares but cannot parse. ⚠️ Shift is required and not optional, for plain URLs too — the
  terminal links section of `.claude/rules/libghostty.md` says why.

**Control API and tooling**

- `tree` reports `sessionRecency`; `keymap list` reports the `nmap` binds in their own section;
  `agtermctl mode on|off|toggle`; `window.list` reports `normalMode`. `.claude/rules/control-api.md`.
- `scripts/release.sh` builds on the fork, unsigned and without a Homebrew tap, and publishes a section of
  `CHANGELOG-vim.md` as the release body. `.claude/rules/release.md`.

## Leader sequences for built-in actions

Upstream dispatches built-in actions as AppKit menu key equivalents, so each takes exactly one chord
and `map` rejects a sequence. Here `map` also accepts one:

```
map ctrl+space>s toggle_split
map ctrl+opt+a>n new_session
```

- The first chord of a sequence must carry a modifier — a bare first key would be swallowed in the
  terminal.
- A sequence **replaces** the action's menu key equivalent. The macOS menu item then shows no
  shortcut, because `NSMenuItem` holds a single key-equivalent character and cannot render a
  two-step sequence. The action palette and the toolbar tooltips show it as joined glyphs (`⌃␣ S`).
- Reserved monitor chords (`ctrl+tab`, `ctrl+1`, `ctrl+2`) are rejected anywhere in a sequence.
- A bare arrow is allowed after the first chord.

## A modal normal mode

A new keyless built-in action `normal_mode`, and a new verb `nmap` for binds that are live only
while the mode is on. Bare keys are legal there, because nothing reaches the terminal.

```
map ctrl+space normal_mode      # enter; i leaves into insert, Esc leaves into the pane's own normal mode

nmap j next_session
nmap k previous_session
nmap h focus_left_pane
nmap l focus_right_pane
nmap g>g first_session
nmap shift+g last_session
nmap s toggle_scratch insert     # a trailing insert leaves the mode as the bind fires
nmap t quick_terminal insert
nmap space>s toggle_split
nmap space>p>a command_palette

nmap e "Annotate last response"  # a quoted target is a custom command, not a built-in
```

A pill in the titlebar shows the mode is on and the armed prefix while a sequence is half-typed.

A quoted `nmap` target names a `command` line by its name. Resolution runs after the whole file is
read, so the `command` may sit above or below the `nmap` that names it, and a name matching nothing is
a parse diagnostic (`unknown command '<name>'`) on the `nmap` line rather than a key that does nothing.

The mode passes OS key repeats through, so holding `k` skims sessions. A command target does not
inherit that: holding `e` spawns one process and the key stays swallowed.

**A bare Esc never enters the mode, deliberately.** Esc has to keep reaching vim, less, fzf and
shell vi-mode, so entry is an explicit chord. Arming a leader requires consuming the key, and a
consumed Esc could not be un-sent to the pty.

**The two ways out differ.** `i` leaves into insert, and sends nothing. Esc leaves and also sends an
Escape keypress to the focused pane, so vim, shell vi-mode and Claude Code's vim mode land in their own
normal mode from the same press — `i` means insert at both layers, Esc means normal at both. Esc that only
abandons a half-typed sequence keeps the mode and sends nothing, and neither does `agtermctl mode off`.

**A third way out fires by itself.** `new_session`, `new_window`, `new_workspace` and `duplicate_session`
each hand over a brand-new pane, so they take the mode off with them and the new shell is typed into
straight away. Vim's `o` is the same bargain: it opens the line and enters insert. Every other action stays
in the mode, and so does a custom command, which has never had a hand-over of its own. The toggles that
also show a pane — `toggle_split`, `toggle_scratch`, `quick_terminal` — stay, so the second bare press that
closes them again still works.

**A mode word overrides that per line, in either direction.** One optional word at the end of an `nmap`
line, `nmap <chord-or-sequence> <action|"<command name>"> [insert|normal]`. `insert` leaves the mode as the
bind fires and, like the bare exit key it is named after, sends no Escape to the pane. `normal` keeps the
mode on. Say nothing and the action decides, so no keymap written before this had to change. The word works
after both target forms, and an unrecognised one is a diagnostic naming it (`unknown mode '<word>'`) that
skips the line. `map` takes no word: a global chord fires outside the mode, where there is no mode to leave.

That word is what the toggles need. Bound to a bare key alone, `s` wants the second press that closes the
scratch; with a global chord for it as well, `nmap s toggle_scratch insert` hands the keys over instead, and
the choice belongs to the keymap rather than to the action.

`map` and `nmap` are independent namespaces — the same chord may appear in both. Bare `s` and the
sequence `space>s` do not conflict, because they differ on their first chord.

### How it owns the keyboard

Normal mode filters keys in the app-wide `keyDown` monitor that already implements leader chords for
custom commands. It does **not** take first responder. An earlier design that did produced three
consecutive bugs — clicking a pane left the mode stuck on, then session navigation killed the mode,
then opening a palette left its text field unable to type — and was deleted.

Consequences worth knowing:

- A Command chord goes to the global matcher, so ⌘⌃F and a Command-bound custom command still fire; one
  that matches nothing passes through, so ⌘Q can never be swallowed and you cannot be trapped.
- A focused text field passes keys through and ends the mode.
- The mode ends on a click in a pane, on a modal taking the keyboard, and on the window resigning key.
- A program overlay (an editor, vifm, `session.overlay.open`) that APPEARS where you already were yields
  the keyboard instead of ending the mode — keys pass to the overlay and the mode is still on when it
  closes — while walking onto an overlay already running, or entering the mode over one, keeps the keys,
  and a yielded key still reaches `map` binds, ⌘⌃F and `ctrl+space`. A HUD is passive and yields nothing.

## 3. Panes wrapped through zmx

Every plain interactive pane is spawned as `zmx attach <key>` instead of a bare login shell, so the
zmx session outlives the app and the app knows which session owns which pane. This replaces a
zprofile hook that used to do the wrapping from outside.

What it buys:

- A pane's foreground process is resolved PAST the zmx client, so `tree --json` reports what you are
  actually running rather than `zmx`.
- Closing or renaming a row ends or relabels its zmx session, and orphaned daemons are reaped at
  launch.
- `session new --command` gained `--keep-shell-open`, which runs the command inside the session's
  shell so the row lands at a prompt when it exits. It excludes `--wait`.

`AGTERM_ZMX_SKIP` (non-empty) leaves a pane unwrapped, and is honoured by the wrapper itself, not
only by the old hook. The UI test launcher sets it, which is not optional.

⚠️ Caveats that are deliberate and will not be fixed by accident — a promoted split survivor is never
zmx-backed again, a runtime attach failure closes the row rather than falling back to a plain shell,
and a detached session whose row left the snapshot is reaped at the next launch. `.claude/rules/zmx.md`
argues each one.

## 4. Overlays open on the machine you are watching from

Every overlay goes through one choke point, `agtermctl session overlay open`. When a laptop is
mirroring a workstation session (or the other way round), that choke point now decides which machine
the overlay draws on, instead of always opening wherever the triggering `agtermctl` happened to run.

- Two optional `Session` fields carry the pairing: `mirrorsSession` (which host and session this one
  mirrors) and its counterpart on the other side. Both are absent on every session that predates this.
- `agtermctl session pairing` sets or clears them; `agtermctl overlay-redirect toggle [on|off|toggle]`
  turns the whole behaviour on and off.
- A redirected open answers with `overlayRedirect` in the response and opens nothing locally, so the
  caller knows the overlay went elsewhere.
- The status HUD is a separate command family and deliberately does NOT redirect.

`overlay_redirect_toggle` is a keyless built-in for the same switch. `.claude/rules/overlay-redirect.md`
owns the design.

## 5. The window's jump-back order, readable

`tree --json` gained `sessionRecency`: the window's jump-back targets, session ids most recent first,
with the active session dropped and the visible navigation scope applied. Before this a script had to
infer the order from what it had itself selected.

⚠️ It is NOT the Ctrl-Tab switcher's list and not `dashboard --mru`. The switcher keeps the active
session at index 0; `dashboard --mru` reads the raw list, every workspace and the active session
included. Do not cite the three as matching.

## 6. A dwell before a session joins the recency order

A session used to enter the recency order the moment it was selected, so walking `j`/`k` through the
sidebar reordered the jump-back list into the order you had just walked. A new **Recency dwell**
setting makes a session wait before it counts: `immediate`, 5, 10, 20, 30 or 60 seconds, defaulting to
20 — not to the zero-wait case, because an existing `settings.json` has no key and a threshold that
only worked once configured would never reach anyone.

- Typing into a session promotes it immediately, without waiting the dwell out.
- ⚠️ `session select` also records immediately, and it is the ONLY command that does. It names one
  session, which is the request to visit it. Everything that STEPS (`session go`, `workspace select`)
  or moves the selection as a side effect stays dwell-gated.
- Read it back as `recencyDwellMs` on the tree and on each `window list` node, omitted when the
  setting is Immediately. Like `autoFollowMs` it is settings-only: no command sets it, deliberately.

## 7. Hidden surfaces release their GPU resources

A hidden pane used to keep its swap chain, per-frame render targets and font atlas textures for the
life of the surface. This fork carries a libghostty patch (`patches/ghostty/`) adding
`ghostty_surface_set_realized`, and unrealizes a surface that stays hidden, freeing all of it. The
shell and terminal state are untouched: an unrealized surface still reads its pty, and the first frame
after realizing shows everything that arrived meanwhile.

- Debounced, and it covers surfaces born hidden.
- On by default; opt OUT with `AGTERM_SURFACE_UNREALIZE=0`.
- `agtermctl tree` tags an unrealized row `(not realized)`, beside `(split hidden)`.

⚠️ The patch is the fork's own and lives in `patches/ghostty/`, applied by `scripts/setup.sh` on top of
the pinned upstream ghostty. When `GHOSTTY_REV` moves it may need rebasing — it applying cleanly is not
proof it still compiles, which is exactly what the 2026-08-18 merge hit.

## 8. The mode pills moved to the sidebar footer

NORMAL and OVERLAY left the title bar. They render at the leading edge of the sidebar footer, and float
in the bottom right corner over the terminal whenever the sidebar is not on screen — including while
terminal zoom is hiding it.

No new setting: the pills moved, they were not made configurable. NORMAL shows the armed leader glyphs
while a sequence is half typed; OVERLAY says which machine the next `session overlay open` targets and
appears only while the overlay redirect is on.

## 9. Open a new session in a chosen workspace

A new keyless built-in `new_session_in_workspace` opens a workspace picker and puts the new session in
whichever workspace you choose, instead of always in the current one.

- The picker is a palette mode of its own, listing workspaces in sidebar order.
- Its free-text row creates a workspace and opens the session in it, so a name that matches nothing is
  a create rather than a dead end. The row is offered even when a title matches partially.
- Bound as a single chord, and reachable from `nmap` like any other built-in.

## Control API

- `agtermctl mode on|off|toggle` — errors when there is no key window, since a mode no keystroke can
  reach would be a lie.
- `window.list` reports `normalMode` on the window holding it, true-only.
- `agtermctl keymap list` gained a `normal mode` section listing `nmap` binds. Each row carries `bind`
  plus exactly one of `action` and `command`, and prints a command target as `command "<name>"`.
- A row also carries `mode` when the line's word CHANGES the outcome, and omits it otherwise. So
  `nmap space>n new_session insert` prints no word, `insert` already being that action's default, and a row
  with no word is a bind running on its default rather than a line that got dropped.

## Also here

- `cookbook/vim-keys/` and `cookbook/vim-keys-cheatsheet/` — ready-to-copy presets.
- `patches/ghostty/` — the fork's own libghostty patches, applied by `scripts/setup.sh` on top of the
  pinned upstream rev.
- `CHANGELOG-vim.md` — the fork's release notes. `CHANGELOG.md` stays upstream's, taken whole on merge.
- `.claude/rules/keymap.md`, `control-api.md`, `zmx.md`, `overlay-redirect.md` and `fork-rebase.md`
  document the design and how the fork is kept current.

## Not done

- README and `site/` upstream docs are not updated. They churn hard upstream, and touching them makes
  every merge a conflict.
- The two features should be two pull requests if this ever goes upstream. Leader sequences alone are
  a small, self-contained diff; the mode roughly doubles it.

Running the UI tests has a constraint of its own; `.claude/rules/ui-tests.md` owns it.
