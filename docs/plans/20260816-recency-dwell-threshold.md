# A dwell threshold before a session counts as visited

## Overview

Walking the sidebar with `j`/`k` currently rewrites the recency order: every session passed through
is recorded as visited. The recent list fills with rows that were on screen for half a second, and
the sessions actually worked in get pushed down.

`AppStore.sessionRecency` feeds the Ctrl-Tab switcher, the title-bar recent popover, the Dock menu,
`dashboard --mru` and the new `sessionRecency` tree field. All of them inherit the problem.

This adds a dwell threshold. A session enters the recency order only once it has been selected
continuously for N seconds, or once the user types in it. N is a Settings value defaulting to 20
seconds. Setting it to Immediately restores today's behaviour exactly.

Fork only. `recordRecency` is upstream code, so this is a rebase collision point by design.

Approved design: `~/.claude/plans/polished-bubbling-yao.md`.

## Context (from discovery)

- `AppStore.recordRecency()` (`agtermCore/Sources/agtermCore/AppStore.swift:453`) is the single
  write seam. All five call sites go through it: `addSession` (409), `selectSession` (437),
  `closeSession` survivor reselection (488), `removeWorkspace` survivor reselection (529), and
  `restore` (864).
- `Debouncer` (`agtermCore/Sources/agtermCore/Debouncer.swift`) is host-free, `@MainActor`, and
  coalescing — `schedule` cancels and replaces any pending action, `flush()` runs it immediately,
  and `fire()` guards on a nil action so `flush()` with nothing pending is a no-op. One instance is
  enough: only one session is selected at a time.
- ⚠️ `noteUserActivity()` (`AppStore+AutoFollow.swift:36`) is called for BOTH a keystroke and a
  manual selection, and nothing distinguishes them at that seam. They are distinct only at the
  callers: the `onUserInput` closures are keystrokes, everything else is selection.
- `AutoFollowAttention` (`AppSettings.swift:102`) is the model for the new setting — a discrete
  picker backed by a raw string, with the full chain AppSettings → SettingsView → SettingsModel →
  AppStore → tree/window.list already in place to copy.
- Timing tests never sleep: set the threshold long, then `flush()`. Pattern at
  `agtermCore/Tests/agtermCoreTests/AppStoreAutoFollowTests.swift:275`.

## Development Approach

- **parallel waves**: none - task 2 needs the store property, tasks 3 and 4 need both the setting
  and the store seam, and the docs task names fields the earlier tasks add.
- **testing approach**: Regular (code first, then tests inside the same task)
- complete each task fully before moving to the next
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- run the narrow per-task command after each change; the wide gates run once in the verify task
- ⚠️ **No test may sleep.** Set the dwell to 100 seconds and drive it with `flush()`.

## Testing Strategy

- **unit tests**: required per task, in `agtermCore/Tests/agtermCoreTests/`
- **e2e tests**: none. `agtermUITests/AutoFollowUITests.swift` shows what an end-to-end version would
  cost — it seeds `settings.json`, relaunches, and polls on real wall-clock time for 5 to 15 seconds.
  The behaviour here is fully reachable host-free.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️

## Solution Overview

One rule, expressed in one place. `recordRecency()` arms a debounced push instead of pushing, and
gains an immediate sibling for the bootstrap path. Typing flushes the pending push. The threshold
travels the same road as the auto-follow timeout, from Settings to each window's store.

Deliberately NOT done: no control command sets the threshold. `autoFollowMs` is settings-only and
read-only over the socket, and this follows it.

## Technical Details

- `RecencyDwell` cases: `immediate, s5, s10, s20, s30, s60`; `immediate` maps to a nil
  `TimeInterval`, which means "push now".
- ⚠️ The tolerant init falls back to `.s20`, NOT to the off case. Every other tolerant init in
  `AppSettings.swift` falls back to off, so this one is deliberately different: an existing
  `settings.json` has no key, and the feature is meant to work without being configured.
- Wire read-back: `recencyDwellMs`, an `Int?` in milliseconds, nil and omitted when immediate.

## What Goes Where

- **Implementation Steps**: the setting, the store, the typing seam, the UI, the read-back, the docs.
- **Post-Completion**: deploy, restart, and the by-hand check.

## Implementation Steps

### Task 1: Add the RecencyDwell setting to the settings model

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift` (add the enum beside `AutoFollowAttention`, and the stored field beside `autoFollowAttention`)
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift` (beside `autoFollowAttentionTolerantInit`)

- [x] add `public enum RecencyDwell` with cases `immediate, s5, s10, s20, s30, s60`, an `init(tolerant raw: String?)` and `var dwell: TimeInterval?` returning nil for `immediate`
- [x] document in the init's doc comment WHY the fallback is `.s20` and not the off case, since every sibling in this file falls back to off
- [x] add `public var recencyDwell: String?` to `AppSettings`
- [x] write tests for the tolerant init, the `.dwell` mapping, and the JSON round trip
- [x] write a test pinning that a settings JSON with NO `recencyDwell` key decodes to `.s20`
- [x] run `cd agtermCore && swift test --filter AppSettingsTests` - must pass before task 2

### Task 2: Make recordRecency wait for the dwell

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the stored-property block holding `autoFollowDebouncer`; `recordRecency()`; the `recordRecency()` call in `restore(from:launchRestore:)`)
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreRecencyDwellTests.swift`

- [x] add `@ObservationIgnored var recencyDwell: TimeInterval?` and `@ObservationIgnored let recencyDwellDebouncer = Debouncer()` to the AppStore class body, NOT an extension — Observation cannot add stored properties in one
- [x] rework `recordRecency()` to schedule the push through the debouncer, capturing the selected id and re-checking `selectedSessionID == pending` inside the closure; keep a `recordRecencyNow()` that pushes immediately, used when `recencyDwell` is nil
- [x] switch the `restore(from:launchRestore:)` call site to `recordRecencyNow()`: that selection earned its place in the previous run
- [x] check whether `reselectIfSelectionHidden` and `replaceSidebarSelection` move `selectedSessionID` without calling `recordRecency`; the equality guard exists for exactly that case, so add a test if either does
  - `replaceSidebarSelection` only writes `sidebarSelectionRaw`, never the selection. `reselectIfSelectionHidden` goes through `selectSession`, so it re-arms — but it moves the selection while the PREVIOUS id is armed, which is the equality guard's case; covered by `unflaggingTheActiveRowDropsItsPendingPush`
- [x] write tests: three fast selections record nothing; the dwell elapsing records; moving away before it records nothing; a fire whose session is no longer selected is dropped; `recencyDwell = nil` behaves exactly as today; restore records immediately
- [x] ⚠️ drive every timing test with `recencyDwell = 100` plus `recencyDwellDebouncer.flush()`, never a sleep
- [x] run `cd agtermCore && swift test --filter 'AppStoreRecencyDwellTests|AppStoreTests'` - must pass before task 3

### Task 3: Let typing promote the pending session

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift` (`noteUserActivity()`)
- Modify: `agterm/agtermApp.swift` (the four `onUserInput` closures)
- Modify: `agterm/Views/WindowContentView.swift` (the `quickTerminal.onUserInput` closure)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRecencyDwellTests.swift` (the file task 2 created)

- [x] add a defaulted `typed: Bool = false` parameter to `noteUserActivity`, flushing `recencyDwellDebouncer` when true, leaving the auto-follow arming unchanged
- [x] update the doc comment, which currently says the call covers "a keystroke or a manual selection" without distinguishing them — that ambiguity is the reason for the parameter
- [x] pass `typed: true` from the five `onUserInput` keystroke closures and from nowhere else; the sidebar, palettes, Dock menu, switcher and recent popover are selections and keep the default
- [x] write tests: typing records the pending session without the timer, typing with nothing pending is a no-op, and typing after the dwell already fired changes nothing
- [x] run `cd agtermCore && swift test --filter AppStoreRecencyDwellTests` and `make build` - both must pass before task 4
  - ⚠️ `make build` was RED before this task for an unrelated reason: the staged `GhosttyKit.xcframework`
    predated `patches/ghostty/0001-surface-realize-api.patch`, so `ghostty_surface_set_realized` was missing.
    `scripts/setup.sh` skips the rebuild whenever the artifact exists, so the stale one was moved aside
    (`/tmp/GhosttyKit.xcframework.stale`) and setup re-ran. Build is green now.

### Task 4: Settings UI and the fan-out to every window

**Files:**
- Modify: `agterm/Views/SettingsView.swift` (a new Section beside the `Auto-follow` Section, and a binding beside `autoFollowAttention`)
- Modify: `agterm/SettingsModel.swift` (`setRecencyDwell` beside `setAutoFollowAttention`; `applyRecencyDwell`/`applyRecencyDwellToAllWindows` beside `applyAutoFollow`)
- Modify: `agterm/ContentView.swift` (beside the `applyAutoFollow(to: resolved)` call)
- Modify: `agterm/agtermApp.swift` (beside the `applyAutoFollowToAllWindows()` call in the scene task)

- [x] add a `Section("Recent sessions")` with one Picker, `.accessibilityIdentifier("settings-recency-dwell")`, labelling the `immediate` case **"Immediately"** rather than "Disabled" — the feature is not off, the wait is zero
- [x] add a `SettingHint` saying a session joins the recent list once you stay this long, or as soon as you type
- [x] add the setter and the per-window fan-out, mirroring the auto-follow pair
  - the fan-out needs a store seam the plan's file list did not name: `AppStore.recencyDwell` is internal,
    so `AppStore.swift` gained `public func setRecencyDwell(_:)` beside `recordRecency`. Switching to
    immediate flushes an armed push instead of dropping it; two tests in `AppStoreRecencyDwellTests` pin that
    and the unchanged-value no-op.
  - the picker writes a raw value for EVERY case, unlike the auto-follow binding which maps its default to
    nil: nil already means `.s20` here, so collapsing the default would leave no way to store `immediate`.
- [x] seed the value where auto-follow is seeded, so a newly opened window and a fresh launch both get it
- [x] run `make build` - must pass before task 5

### Task 5: Report the threshold on the tree and window.list

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift` (beside the `autoFollowMs` computed property)
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`ControlTree`, beside `autoFollowMs`)
- Modify: `agtermCore/Sources/agtermCore/ControlWindowNode.swift` (beside its `autoFollowMs`)
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the `ControlTree(...)` construction) and `WindowLibrary.swift` (`controlWindowNodes`)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift` and `WindowLibraryTests.swift`

- [x] add `recencyDwellMs` as `recencyDwell.map { Int($0 * 1000) }`, nil when immediate
- [x] add the field to `ControlTree` and `ControlWindowNode`, including each custom init, and populate both
- [x] add no control command to SET it: `autoFollowMs` is settings-only and read-only, and this follows it
- [x] write the omit-when-nil and round-trip pair for both the tree and the window node
  - plus `theTreeReportsTheDwellInMilliseconds` in `AppStoreRecencyDwellTests`, since the tree POPULATION
    is store-side and the protocol tests only cover the wire shape
- [x] extend `controlWindowNodesProjectListMetadata` to cover the new field
- [x] run `cd agtermCore && swift test --filter 'ControlProtocolTests|WindowLibraryTests'` - must pass before task 6
  - ⚠️ `SkillInstallTests.bundledSkillDocumentsSessionRecency` is RED from here until task 6: it counts
    `ControlTree`'s fields off the type (now 14) and compares against the skill prose, which still says
    thirteen. Task 6 moves both counts.
  - the first `swift test` after the signature change failed to LINK: `SocketClientTests.swift.o` was not
    recompiled against the new `ControlTree`/`ControlWindowNode` inits. `touch`ing that file cleared it.

### Task 6: Document the setting and the new field

**Files:**
- Modify: `plugins/agterm/skills/agterm/reference.md` (the paragraph that enumerates the tree top-level fields and states their count)
- Modify: `plugins/agterm/skills/agterm/SKILL.md` (the sentence stating the top-level field count)
- Modify: `.claude/rules/settings.md` and `.claude/rules/control-api.md`

- [x] add `recencyDwellMs` to the tree field catalog and to the `window.list` field list, and move each stated count on
- [x] ⚠️ derive both counts from the code, not from the existing prose — those numbers have drifted before
  - counted off `ControlTree` itself: thirteen → fourteen. `SkillInstallTests` pins the number twice, in
    prose and as `fields.count`, so the test moved with the docs; it is the code-derived half of the pin.
- [x] add a line to `.claude/rules/settings.md` for the new setting and to `.claude/rules/control-api.md` for the new read-back
- [x] run `cd agtermCore && swift test --filter SkillInstallTests` - must pass before task 7

### Task 7: Verify acceptance criteria

- [ ] verify a fast walk through several sessions records none of them
- [ ] verify the dwell elapsing records, and that typing records sooner
- [ ] verify Immediately reproduces today's behaviour exactly
- [ ] run full host-free suite: `cd agtermCore && swift test`
- [ ] run `make lint` - zero findings required
- [ ] run `make test-app`. ⚠️ It is RED on a clean checkout for unrelated reasons — exit 2, zero failing test cases, test-host crash restarts at process exit. Compare against the base commit and do NOT chase it; a separate session owns that investigation

### Task 8: [Final] Update documentation

- [ ] confirm no other in-repo surface states the tree field count or lists the settings
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- Build and deploy, then restart agterm. The user decides when to restart; every live session lives
  in that process.
- Walk `j`/`k` through five sessions quickly, press Tab, and confirm none of the five appear. Sit in
  one for 20 seconds and confirm it does.

**Behaviour changes to expect:**
- Ctrl-Tab's "previous session" becomes the last session actually worked in, not the last one
  touched. This is the point of the change, but it is a daily-driver behaviour.
- The Dock menu, the title-bar recent popover and `dashboard --mru` change with it — same stack.
- A session never dwelt in is invisible to all of them, including across a restart, since the stack
  is what gets persisted.
