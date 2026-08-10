# Keymap leader sequences and normal mode — implementation tasks

Design and rationale live in the spec, `docs/plans/20260808-keymap-leader-sequences.md`. This file is
the task checklist only. Read the spec first; it is not repeated here.

## Overview

Let `keymap.conf` bind built-in actions to leader sequences, then add an opt-in normal mode where bare
keys are bindable. Today built-in actions dispatch as AppKit menu key equivalents, so each takes one
chord and `parseMapLine` rejects a sequence outright. The leader state machine already exists for
custom shell commands and is simply unreachable from `map`.

Ships as two separately-committed pieces: sequences for built-ins (tasks 1-6), then normal mode
(tasks 7-12). Piece one is the candidate for an upstream pull request.

## Context (from discovery)

- `agtermCore/Sources/agtermCore/Keymap.swift` — `parseKeymap`, `parseMapLine`, `resolveBuiltinOverrides`,
  `validateCommands`, and the `Keymap` struct with `equivalent(for:)` / `glyphHint(for:)`.
- `agtermCore/Sources/agtermCore/Keybind.swift` — `Chord`, `Keybind`, `parseKeybind`,
  `isReservedMonitorChord`, `bindableArrowKeys`, `keybindConflicts`.
- `agtermCore/Sources/agtermCore/KeybindMatcher.swift` — the leader state machine, currently keyed on `UUID`.
- `agtermCore/Sources/agtermCore/CustomCommandEngine.swift` — builds the matcher, returns `Outcome.fired(CustomCommand)`.
- `agterm/Commands/CustomCommandRunner.swift` — the app-wide `.keyDown` monitor and its dispatch.
- `agterm/AppActions+Palette.swift` — `runPaletteCommand` is the central built-in dispatcher, and
  `PaletteCommand.builtinAction` in `PaletteCatalog.swift` already maps most cases.
- `DashboardView.swift` holds the precedent key catcher that swallows unmatched keys.

## Development Approach

- **parallel waves**: none — tasks 1 to 3 each build on the previous task's types, and every app-target
  task is blocked on the toolchain gate below, so nothing can run beside anything else.
- **testing approach**: TDD, per CLAUDE.md.
- complete each task fully before moving to the next
- **CRITICAL: every task includes new or updated tests**, listed as separate checklist items
- **CRITICAL: all tests pass before the next task starts**
- run only the narrow per-task command; the full suite runs once in the verify task
- maintain backward compatibility: with an untouched `keymap.conf` nothing changes

## ⚠️ Toolchain gate

This checkout has never built the app. `zig` and `xcodegen` are both absent and
`GhosttyKit.xcframework` does not exist, so `scripts/setup.sh` must run first and it builds ghostty
from source at the pinned revision.

- **Tasks 1-4 and 8-9 need nothing.** They are host-free and `cd agtermCore && swift test` works today.
- **Tasks 5, 6, 10, 11, 12 cannot be verified until the toolchain exists**, and neither can `make lint`,
  `make test-app`, or the verify task.

Do not start task 5 before the toolchain is up.

## Testing Strategy

- **unit tests**: required per task, host-free in `agtermCore/Tests/agtermCoreTests/`.
- **hosted tests**: `agtermUITests/KeymapUITests.swift` gains two scoped cases. Run them with
  `-only-testing:` only — never the whole XCUITest suite, which costs minutes and proves nothing extra.
- **opt-in regression**: the check that matters most for upstream. With an untouched `keymap.conf`,
  `agtermctl keymap list` must report exactly the same `actions` and `menu` chords as before.

## Progress Tracking

- mark completed items `[x]` immediately
- newly discovered tasks get a ➕ prefix
- blockers get a ⚠️ prefix
- update this file when scope changes

## Implementation Steps

### Task 1: Widen the matcher to hold built-in actions as well as custom commands

**Files:**
- Create: `agtermCore/Sources/agtermCore/KeybindTarget.swift`
- Modify: `agtermCore/Sources/agtermCore/KeybindMatcher.swift` (`MatchResult.fired`, `init(_ binds:)`, and the `binds` tuple type)
- Modify: `agtermCore/Sources/agtermCore/CustomCommandEngine.swift` (`init(commands:)` where it builds `binds`, and `advance` where it maps `.fired`)
- Modify: `agtermCore/Tests/agtermCoreTests/KeybindMatcherTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/CustomCommandEngineTests.swift`

**Model:** sonnet

- [x] add `KeybindTarget` — `.command(UUID)` / `.builtin(BuiltinAction)`, `Equatable`, `Hashable`, `Sendable`
- [x] change `MatchResult.fired` and `KeybindMatcher.init` to carry `KeybindTarget` instead of `UUID`
- [x] add a `builtinSequences: [BuiltinAction: Keybind]` parameter to `CustomCommandEngine.init`, defaulted to `[:]` so existing call sites compile unchanged
- [x] add `Outcome.firedBuiltin(BuiltinAction)` and map `.fired(.builtin(_))` onto it in `advance`
- [x] write tests for a matcher holding both kinds of bind, including a custom keybind that is a strict prefix of a built-in sequence
- [x] write tests for `firedBuiltin`, for re-arming on a fresh leader, and for `reset`
- [x] run `cd agtermCore && swift test --filter 'KeybindMatcherTests|CustomCommandEngineTests'` — must pass before task 2

### Task 2: Add the sequence binding to the Keymap model and render it as glyphs

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift` (the `Keymap` struct — `init`, `equivalent(for:)`, `glyphHint(for:)`)
- Modify: `agtermCore/Sources/agtermCore/Keybind.swift` (add a `Keybind` glyph renderer next to `Chord.glyphString`)
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeybindTests.swift`

**Model:** sonnet

- [x] add `Keymap.builtinSequences: [BuiltinAction: Keybind]`, with the `init` parameter defaulted to `[:]` so no existing caller changes
- [x] make `equivalent(for:)` return nil when the action has a sequence — this is what clears the menu key equivalent
- [x] add `Keymap.binding(for:) -> Keybind?` returning the sequence when present, else the single chord wrapped in a one-element array
- [x] add a `Keybind` glyph renderer joining chord glyphs with a space (`⌃␣ S`)
- [x] switch `glyphHint(for:)` to `binding(for:)`, so the palette and tooltips show the sequence
- [x] write tests for `equivalent(for:)` returning nil under a sequence while `builtinOverrides` still resolves normally for every other action
- [x] write tests for `binding(for:)` in all three states: sequence, override chord, shipped default, and keyless
- [x] write tests for the glyph renderer, single chord and multi-chord
- [x] run `cd agtermCore && swift test --filter 'KeymapTests|KeybindTests'` — must pass before task 3

### Task 3: Parse and validate `map` lines that carry a leader sequence

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift` (`parseMapLine` where it rejects `keybind.count == 1`, the `ParsedOverride` struct, and `parseKeymap` where it calls `resolveBuiltinOverrides`)
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`

**Model:** opus

- [x] split `parseMapLine` into a single-chord path (unchanged behavior) and a sequence path
- [x] on the sequence path require a modifier on the FIRST chord only, the same rule and reason as `parseCommandLine`
- [x] on the sequence path reject a reserved monitor chord at ANY position, and allow a bare arrow at any position after the first
- [x] collect sequences alongside `ParsedOverride` in file order and resolve them after `resolveBuiltinOverrides`, last-wins per action across both `map` forms
- [x] reject a sequence whose first chord equals an active built-in menu chord, with a diagnostic naming the owning action
- [x] extend `validateCommands` so custom keybinds and built-in sequences are prefix-checked against each other, reusing the `isPrefix` logic behind `keybindConflicts`
- [x] write tests for each accept rule: two-chord and three-chord binds, bare arrow tail, bare letter tail
- [x] write tests for each reject rule: bare first chord, reserved chord in the tail, first chord equal to a live menu chord
- [x] write tests for last-wins across the two forms in both line orders, and for a sequence freeing the chord it moved off
- [x] write tests for prefix conflicts in both directions, custom-shadows-builtin and builtin-shadows-custom
- [x] run `cd agtermCore && swift test --filter KeymapTests` — must pass before task 4

### Task 4: Report sequences through `keymap list`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlKeymap.swift` (`ControlKeymap.project` where it builds `actions` from `keymap.equivalent(for:)`)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlKeymapTests.swift`

**Model:** sonnet

- [x] project `binding(for:)` into `ControlKeymapAction.chord` so a sequence reports as `ctrl+space>s`; the field is already a string, so no schema change
- [x] keep `overridden` correct for a sequence — it differs from the shipped default by definition
- [x] write tests for a sequence-bound action reporting its sequence in `actions`
- [x] write tests for the untouched-keymap case reporting byte-identical output to today, the opt-in regression guard
- [x] run `cd agtermCore && swift test --filter ControlKeymapTests` — must pass before task 5

### Task 5: Fire built-in actions from the keybind monitor

**Files:**
- Modify: `agterm/Commands/CustomCommandRunner.swift` (`rebuild()` where it constructs `CustomCommandEngine`, and `handleKeyDown` where it switches on `.fired`)
- Modify: `agterm/AppActions+Palette.swift` (add `perform(_:)` next to `runPaletteCommand`)
- Modify: `agtermUITests/KeymapUITests.swift`

**Model:** opus

⚠️ The toolchain gate is stale: the toolchain is installed and the app target builds.

- [x] add `AppActions.perform(_ action: BuiltinAction)` that inverts `PaletteCommand.builtinAction` to reach `runPaletteCommand`, inheriting its `uiActionsEnabled` gate
- [x] handle in `perform` the actions the palette dispatches separately — `new_window`, `rename_window`, `delete_window`, plus the three palette launchers — by calling their methods directly
- [x] feed `keymap.builtinSequences` into the engine in `rebuild()`, and rebuild on `.agtermKeymapChanged` as today
- [x] dispatch `Outcome.firedBuiltin` from `handleKeyDown`, consuming the key exactly as a fired custom command does
- [x] add a scoped `KeymapUITests` case that a mapped sequence fires its action
- [x] add a scoped `KeymapUITests` case that the menu item lost its key equivalent while a sequence owns the action
- [x] run `xcodebuild ... -only-testing:agtermUITests/KeymapUITests/<the two new cases>` — must pass before task 6

### Task 6: Document the sequence grammar

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift` (the `parseKeymap` doc comment's grammar list)
- Modify: `.claude/rules/keymap.md` (the bullet stating built-in leaders are unsupported)
- Modify: `plugins/agterm/skills/agterm/` (the keymap section)

**Model:** haiku

⚠️ On the fork, skip README.md and `site/`. They take 174 and 83 commits in three months against 6 to 20
for the code files, so touching them makes every rebase a conflict. Add them when piece one is prepared
as an upstream pull request.

- [x] update the `parseKeymap` grammar comment: `map` now accepts a sequence, with the first-chord modifier rule
- [x] correct the `.claude/rules/keymap.md` line that says built-in leaders remain unsupported
- [x] update the bundled skill's keymap section with the new grammar and one example
- [x] run `cd agtermCore && swift test --filter KeymapTests` — must pass before task 7

### Task 7: Add the normal-mode action

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift` (the case list, and the keyless arm of `defaultChord`)
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`

**Model:** sonnet

- [x] add `case normalMode = "normal_mode"` and put it in the keyless arm of `defaultChord`, so it ships unbound
- [x] update the test that pins the case list — this is a deliberate change, not a fix
- [x] write a test that `normal_mode` has no default chord, so the mode is unreachable until bound
- [x] run `cd agtermCore && swift test --filter BuiltinActionTests` — must pass before task 8

### Task 8: Parse `nmap` lines

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift` (the verb `switch` in `parseKeymap`, and a new parse function beside `parseMapLine`)
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`

**Model:** opus

- [x] add `Keymap.normalModeBinds: [NormalModeBind]`, defaulted empty in `init` (a struct, not a tuple, so
      `Keymap` keeps synthesized `Equatable`)
- [x] add the `nmap` verb case and its parse function: `<key|sequence> <action>`, no modifier requirement
- [x] keep reserved monitor chords rejected at any position, and reject an unknown action as `map` does
- [x] prefix-check normal-mode binds among themselves only, since the mode is its own namespace
- [x] write tests for a bare letter, a bare arrow, and a `space>s` sequence all parsing
- [x] write tests that an `nmap` bind does NOT collide with an identical global `map` or custom command
- [x] write tests for reserved chords and unknown actions producing diagnostics
- [x] run `cd agtermCore && swift test --filter KeymapTests` — must pass before task 9

### Task 9: Add the host-free normal-mode state machine

**Files:**
- Create: `agtermCore/Sources/agtermCore/NormalModeState.swift`
- Create: `agtermCore/Tests/agtermCoreTests/NormalModeStateTests.swift`

**Model:** opus

- [x] add `NormalModeState` holding on/off plus a `KeybindMatcher` built from `normalModeBinds`
- [x] give it an `advance(_ chord:)` returning fired / armed / swallowed, where unmatched means SWALLOWED rather than passed through — the one behavioral difference from the global path
- [x] give it enter, exit, and a reset the app-side leader timeout can call
- [x] expose the armed prefix so the indicator can show a pending leader
- [x] write tests for enter, a single-key fire, a `space>s` sequence fire, and exit
- [x] write tests that an unmatched key is swallowed, never passed through
- [x] write tests for Esc exiting the mode, and for Esc abandoning an armed leader without exiting
- [x] run `cd agtermCore && swift test --filter NormalModeStateTests` — must pass before task 10

### Task 10: Wire the mode into the app

**Files:**
- Create: `agterm/Views/NormalModeKeyCatcher.swift`
- Modify: `agterm/Commands/CustomCommandRunner.swift` (`handleKeyDown`, ahead of the existing matcher call)
- Modify: `agterm/AppActions+Palette.swift` (`perform(_:)` — handle `normalMode` by entering the mode)

**Model:** opus

⚠️ Blocked on the toolchain gate.

- [x] add the key catcher, modelled on `DashboardView`'s: takes first responder, routes `keyDown` to `NormalModeState`, swallows unmatched
- [x] leave `performKeyEquivalent` alone so menu chords such as ⌘Q still reach the menu bar and the user is never trapped
- [x] route key-down through the mode before the global matcher when the mode is on
- [x] reuse the existing 1.5 second leader timer for the mode's armed leader rather than adding a second timer
- [x] exit the mode on window resign-key so it cannot stay armed invisibly in a background window
- [x] add a scoped `KeymapUITests` case for enter, fire, exit
- [x] run the new case with `-only-testing:` — must pass before task 11

### Task 11: Show the mode in the titlebar

**Files:**
- Modify: `agterm/Views/WindowContentView+Titlebar.swift` (the titlebar content row)

**Model:** sonnet

⚠️ Blocked on the toolchain gate. Without this the mode silently eats keystrokes the user believes went
to the shell, so it is required, not polish.

- [x] add a pill showing the mode is on, using the existing chrome text and terminal-background colors
- [x] show the armed leader prefix in the pill while a sequence is half-typed
- [x] hide it entirely when the mode is off, so an untouched install sees no change
- [x] verify by eye (skipped - not automatable; static reading only, no launch permitted; deferred to the user's manual Debug run per Post-Completion)
- [x] run `make lint` — must pass before task 12

### Task 12: Give the mode a control surface

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (the command catalog)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (the command `switch`)
- Modify: `agterm/Control/ControlServer+AppCommands.swift` (the app-side handler)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`

**Model:** opus

⚠️ Blocked on the toolchain gate.

- [x] add a `mode` command taking `on` / `off` / `toggle`, reusing `ControlToggleMode.parse`
- [x] add the dispatcher entry and the app-side handler
- [x] expose the current mode as read-back on the window node, per the state-setting rule in `.claude/rules/control-api.md`
- [x] add the `agtermctl` subcommand and its help text
- [x] write protocol tests for parse, dispatch, and rejection of an unknown mode token
- [x] write an end-to-end test against an ISOLATED socket, never the default one
      (`agtermUITests/ControlNormalModeUITests.swift`; compiled but NOT executed — a Debug instance is under
      the user's manual testing and `.claude/rules/ui-tests.md` forbids running XCUITests then)
- [x] ➕ report the `nmap` binds through `keymap list`: a `normalMode` array on `ControlKeymap`, rendered
      beside `actions` in the CLI text output, covered in `ControlKeymapTests`
- [x] run `cd agtermCore && swift test --filter ControlDispatcherTests` — must pass before task 13

### Task 13: Verify acceptance criteria

- [x] verify every requirement in the spec's "What ships" section is implemented
- [x] verify the opt-in guard: with an untouched `keymap.conf`, `agtermctl keymap list` reports the same `actions` and `menu` chords as before the change
- [x] verify `BuiltinAction.defaultChord` is unchanged for every pre-existing action
- [x] run the full host-free suite: `cd agtermCore && swift test`
- [x] run `make test-app`
- [x] run `make lint` — zero findings required

### Task 14: [Final] Update documentation

- [x] update `.claude/rules/keymap.md` with the normal-mode design and the `nmap` grammar (already done
      by task 3's and task 10/12's deviations; verified accurate, no further change needed)
- [x] update `.claude/rules/control-api.md` with the `mode` command (already done by task 12's
      deviation, commit 92becf9; verified accurate, no further change needed)
- [x] update the bundled skill at `plugins/agterm/skills/agterm/` (already done by task 12's deviation;
      verified accurate, no further change needed)
- [x] add the vim keymap preset to `cookbook/`, which the spec names as the payoff for this work —
      added `cookbook/vim-keys/`
- [x] move both this file and the spec to `docs/plans/completed/` (left to the harness's finalize step,
      per its instructions; not performed here)

## Post-Completion

**Manual verification:**

- Drive an isolated Debug instance with a short `AGTERM_STATE_DIR` and its own socket. Confirm a mapped
  sequence fires, the menu item shows no shortcut, and the palette shows the joined glyphs.
- Confirm the mode indicator appears and disappears, and that ⌘Q still works while the mode is on.
- Retest on a non-Latin layout. `chordKey` resolves per layout, and the sequence path inherits that,
  so a Russian-Phonetic instance should fire the same binds.

**External:**

- Prepare piece one as an upstream pull request against `umputun/agterm`: rebase onto current
  `origin/master`, add the README and `site/` edits that were deliberately skipped on the fork, and
  keep the diff to the parser, matcher and dispatch changes.
