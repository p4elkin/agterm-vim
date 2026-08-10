# What this build adds over upstream agterm

This is a build of [umputun/agterm](https://github.com/umputun/agterm) with vim-style keyboard
navigation added. Everything upstream does, it still does. The additions are opt-in: with an
untouched `keymap.conf` the key path is byte-for-byte what upstream ships, and a test pins that
(`ControlKeymapTests.untouchedKeymapProjectsExactlyTheShippedDefaultForEveryAction`).

Forked at `82e4253`. Two separable features.

## 1. Leader sequences for built-in actions

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

## 2. A modal normal mode

A new keyless built-in action `normal_mode`, and a new verb `nmap` for binds that are live only
while the mode is on. Bare keys are legal there, because nothing reaches the terminal.

```
map ctrl+space normal_mode      # enter; i or Esc leaves

nmap j next_session
nmap k previous_session
nmap h focus_left_pane
nmap l focus_right_pane
nmap g>g first_session
nmap shift+g last_session
nmap s toggle_scratch
nmap t quick_terminal
nmap space>s toggle_split
nmap space>p>a command_palette
```

A pill in the titlebar shows the mode is on and the armed prefix while a sequence is half-typed.

**A bare Esc never enters the mode, deliberately.** Esc has to keep reaching vim, less, fzf and
shell vi-mode, so entry is an explicit chord. Arming a leader requires consuming the key, and a
consumed Esc could not be un-sent to the pty.

`map` and `nmap` are independent namespaces — the same chord may appear in both. Bare `s` and the
sequence `space>s` do not conflict, because they differ on their first chord.

### How it owns the keyboard

Normal mode filters keys in the app-wide `keyDown` monitor that already implements leader chords for
custom commands. It does **not** take first responder. An earlier design that did produced three
consecutive bugs — clicking a pane left the mode stuck on, then session navigation killed the mode,
then opening a palette left its text field unable to type — and was deleted.

Consequences worth knowing:

- Command chords always pass through, so ⌘Q can never be swallowed and you cannot be trapped.
- A focused text field passes keys through and ends the mode.
- The mode ends on a click in a pane, on a modal taking the keyboard, and on the window resigning key.

## Control API

- `agtermctl mode on|off|toggle` — errors when there is no key window, since a mode no keystroke can
  reach would be a lie.
- `window.list` reports `normalMode` on the window holding it, true-only.
- `agtermctl keymap list` gained a `normal mode` section listing `nmap` binds.

## Also here

- `cookbook/vim-keys/` — a ready-to-copy preset.
- `.claude/rules/keymap.md` and `control-api.md` document the design.

## Not done

- README and `site/` upstream docs are not updated. They churn hard upstream, and touching them makes
  every rebase a conflict.
- `agtermUITests/ControlNormalModeUITests` was written before XCUITest could run here. What blocked it
  was an unanswered "XCTest is trying to Enable UI Automation" password prompt, fixed for good with
  `sudo DevToolsSecurity -enable`. Both tests in the class now pass.
  On its first run `testModeOnShowsIndicatorAndReadsBackOnTheWindow` failed on the pill lookup. The mode
  and the pill were both fine; the query was the problem. `descendants(matching: .any)` builds the whole
  accessibility tree, terminal grid included, and on a freshly launched window that first snapshot can
  outlast a 10s timeout — so asking for the pill as the very first thing after `mode on` fails without
  ever reaching it. Asserting the `window.list` read-back first gives the app one round trip to go idle.
  The assertion order is therefore load-bearing and the test says so.
- The two features should be two pull requests if this ever goes upstream. Leader sequences alone are
  a small, self-contained diff; the mode roughly doubles it.
