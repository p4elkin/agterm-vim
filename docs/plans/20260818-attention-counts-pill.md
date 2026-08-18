# Attention counts pill

## Overview

When the sidebar is collapsed every per-session signal disappears at once: the status glyphs, the
unseen badges, the workspace roll-ups. Sasha now works with the sidebar collapsed most of the time,
so that is the normal case rather than the exception.

The one thing that already covers it does not work for this. The title bar attention bell is opt-in
and off by default (`settings.attentionButtonEnabled ?? false`, `agterm/SettingsModel.swift:670`),
and it is three states with no count (`agterm/Views/WindowContentView+RecentSessions.swift:118`) —
it says something needs you, never how much or what kind.

This adds a pill that carries the counts. It joins the existing chrome pills, so it appears in the
sidebar footer when the sidebar is up and floats bottom-right over the terminal when it is not.
That behavior already exists and is inherited for free.

The bell is left exactly as it is, including its default-off setting. Anyone who wants it keeps it.

Fork-only feature. It is not offered upstream.

## Context (from discovery)

- **Files involved**: `agtermCore/Sources/agtermCore/AppStore+Status.swift` (73 lines),
  `agterm/Views/WindowContentView+Titlebar.swift` (317 lines),
  `agterm/Views/WindowContentView.swift`, plus two new files.
- **Patterns to reuse**: `AppStore.attentionSessions` (`AppStore+Status.swift:58`) already spans
  every workspace in the window, drops idle sessions, and sorts by `attentionRank`.
  `overlayRedirectPill` (`WindowContentView+Titlebar.swift:200-217`) is the pill shape and, in
  `overlayRedirectPillState` (line 227), the pattern of factoring the decision out as a static
  function so a test can drive it without instantiating the view.
  `agtermTests/OverlayRedirectPillTests.swift` is the test shape.
- **Dependencies identified**: `AgentStatus` (`agtermCore/Sources/agtermCore/AgentStatus.swift`),
  `AppStore.activeSession` (`AppStore.swift:201`),
  `GhosttyApp.statusColor(for:)` (`agterm/Ghostty/GhosttyApp.swift:269`),
  `BadgeView` (`agterm/Views/SidebarRowViews.swift:82`).
- **What the pill inherits by joining `chromePills`**: both render sites, the `sidebarOnScreen`
  gate, and frontmost-window-only rendering. No new plumbing.

## Development Approach

- **parallel waves**: none — task 2 needs the type from task 1, task 3 needs the accessor from
  task 2, and tasks 1 through 3 all touch the same feature surface.
- **testing approach**: TDD — write the failing test first in each task, then the code.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting the next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run the narrow per-task command after each change; the wide gates run once in the verify task
- maintain backward compatibility

⚠️ **Never touch the user's live terminal.** agterm is the terminal Sasha is working in right now.
Never run `agterm` or `agtermctl` against the default socket, never launch or quit the app, static
reading and building only. Verify behavior through the tests below, never by driving the running
app.

⚠️ **Module boundary.** `agtermCore` is host-free. It must not import GhosttyKit, AppKit, Metal or
CoreGraphics, and must not use `CGSize`/`CGPoint`/`CGRect`/`CGFloat` — those pass Debug and tests
but crash Release whole-module optimization.

⚠️ **New files, not appended logic.** `WindowContentView+Titlebar.swift` and `AppStore.swift` are
among the files that collide most on rebase against upstream (`.claude/rules/fork-rebase.md`).
Keeping the pill's body in its own file means a future conflict lands on a one-line edit and never
on the feature.

## Testing Strategy

- **unit tests**: required for every task. Host-free rule tests in `agtermCoreTests`, view-state
  tests in `agtermTests`.
- **e2e tests**: none. This project's XCUITests are slow and prove nothing extra here.
  ⚠️ Do not run a whole XCUITest suite to check this. `agtermUITests/ControlAPIUITests` alone is 82
  methods and about 7.5 minutes and tells you nothing a targeted run does not.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update this plan if implementation deviates from the original scope

## Solution Overview

One capsule holding a segment per non-zero category, each a distinct SF Symbol plus a count, tinted
by the configured status color.

```
  NORMAL   ✋2  ▶3  ✓1  ✉4
           └───────────────┘
              the new pill

  ✋2   blocked    sessions on a permission prompt
  ▶3   active     sessions currently working
  ✓1   completed  finished, waiting to be looked at
  ✉4   unseen     unread notifications on the CURRENT session
```

Rules:

- **A category with a count of zero renders nothing.** One blocked session and nothing else shows
  `✋1` alone.
- **An entirely quiet window shows no pill at all**, matching `normalModePill` (absent while the
  mode is off) and `overlayRedirectPill` (absent while the toggle is off).
- **Order is blocked, active, completed, then unseen.** The first three follow
  `AgentStatus.attentionRank` (`AgentStatus.swift:26`) so the pill reads left to right in the same
  order the attention palette reads top to bottom. Unseen sits last because it counts a different
  kind of thing.
- **Distinct glyph per category, not the sidebar's single configurable shape.** A lone number has to
  say which category it is without depending on color. ⚠️ This is a deliberate break from the
  sidebar, which uses one `StatusShape` for every status and distinguishes by color alone. The pill
  does not follow that setting. Do not "fix" this to match the sidebar.
- **The pill is informational. It is not clickable.** Navigation stays where it is: ⌃⇧I for the
  attention palette and ⌃⌥↑/↓ to step through.

### Key design decisions

- `unseen` is the active session's count alone, not a sum across sessions.
  `WindowLibrary.totalUnseenCount` already sums unseen across every window for the Dock badge; this
  answers the different question of whether the session in front of you has something unread.
- The counting rule takes plain inputs (`[AgentStatus]` and an `Int`), not an `AppStore`, so it is
  testable with no host and cannot drift from the view.
- Reuse `attentionSessions`; do not re-derive its filter. A second copy of "non-idle across every
  workspace in this window" is a thing that can silently disagree with the palette and the bell.

## Technical Details

Host-free type, in the new `AttentionCounts.swift`:

```swift
public struct AttentionCounts: Equatable, Sendable {
    public let blocked: Int
    public let active: Int
    public let completed: Int
    public let unseen: Int

    public var isEmpty: Bool { blocked == 0 && active == 0 && completed == 0 && unseen == 0 }

    /// Takes the raw inputs rather than an AppStore so the rule is testable with no host.
    public static func make(statuses: [AgentStatus], activeUnseen: Int) -> AttentionCounts
}
```

Store accessor, in `AppStore+Status.swift`:

```swift
public var attentionCounts: AttentionCounts {
    AttentionCounts.make(statuses: attentionSessions.map(\.agentIndicator.status),
                         activeUnseen: activeSession?.unseenCount ?? 0)
}
```

View notes:

- ⚠️ **Do not touch `allowsHitTesting(false)` on `floatingPillsLayer`**
  (`agterm/Views/WindowContentView.swift:429-436`). That layer fills the whole window so the pills
  can sit bottom-trailing, so enabling hit testing there makes it swallow every click in the
  window — a bug that shows up as clicks failing somewhere unrelated. The pill is informational
  precisely so this stays untouched.
- ⚠️ **Use `sidebarOnScreen`, not `store.sidebarVisible`.** `sidebarVisible` stays set through
  terminal zoom and the dashboard, which are exactly the cases where the footer is mounted but
  invisible. Joining `chromePills` gets the correct predicate for free at both render sites
  (`WindowContentView.swift:599`, `:680`, `:430`); do not add a second gate of your own.
- `chromePills` is already wrapped in `if library.activeWindowID == windowID`, so the pill is
  per-window and only on the frontmost one. That is the intended scope. Do not widen it.
- Colors: `GhosttyApp.shared.statusColor(for:)` for the three statuses so the pill follows the same
  Settings colors as the sidebar glyphs; the unseen segment matches `BadgeView`'s color so the
  collapsed and expanded views agree on what unread looks like.
- Follow `overlayRedirectPill`'s capsule shape and caption sizing, not `normalModePill`'s inverted
  style, which is reserved for signalling a mode that eats keystrokes.
- Candidate SF Symbols: `hand.raised.fill`, `play.fill`, `checkmark`, `envelope.fill`. Verify each
  resolves at the deployment target; substitute a near neighbour if one does not.
- Accessibility identifier `attention-counts-pill`, with the counts exposed through
  `.accessibilityValue` so a test can read them, the way the bell exposes its
  `none|attention|blocked` state.

### Out of scope — do not add these

- **No new control command and no read-back field.** Every input is already reachable through
  `tree --json`: each session's status and unseen count are on `ControlSessionNode`. The pill only
  arranges facts the control API already reports, so this is a genuine visual-only exemption from
  the cross-surface rule in CLAUDE.md, not an oversight. Do not invent a command for it.
- **No new `InterfaceElement` and no Settings entry.** Gating follows `overlayRedirectPill`, whose
  own comment gives the principle: it needs no toggle because it is already gated on the one
  condition that makes it mean anything. Here that condition is having something to report. Adding
  a hideable element also requires explicit approval per CLAUDE.md, which has not been given.
- ⚠️ **Do NOT touch `plugins/agterm/skills/agterm/`, `site/commands.html` or `README.md`.** This is
  a fork-only feature. Those surfaces describe upstream agterm, and the bundled skill pins an
  upstream command count that `SkillInstallTests` checks — editing them breaks that test. Fork-only
  work is documented in `.claude/rules/` only.
- **Do not touch `CHANGELOG.md`.** It is release-only. Fork release notes live in
  `CHANGELOG-vim.md` and are not part of this work.
- ⚠️ **The message count is deferred, deliberately.** Sasha wants a fifth segment for new peer
  messages, with its own count and its own glyph, fed by a generic control command rather than
  anything wired to xchat. It is out of scope here because the command's contract depends on a
  peer-messaging design being brainstormed in another session, and inventing it now would ship a
  command that then has to change. Build the segment list as a table so adding a fifth category is
  an addition rather than a restructure. Do not implement the message count in this run.

## Implementation Steps

### Task 1: AttentionCounts type and its counting rule

**Files:**
- Create: `agtermCore/Sources/agtermCore/AttentionCounts.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AttentionCountsTests.swift`

- [x] write failing tests in `AttentionCountsTests`: each of `blocked`/`active`/`completed` lands in
      its own bucket; a mixed array counts all three correctly
- [x] write failing tests for the edges: empty `statuses` with zero `activeUnseen` gives `isEmpty`;
      `activeUnseen` passes through unchanged; a stray `.idle` in `statuses` is counted into nothing
      and does not make `isEmpty` false on its own
- [x] create `AttentionCounts.swift` with the struct, `isEmpty`, and
      `make(statuses:activeUnseen:)` — no AppKit, no CoreGraphics types
- [x] run `cd agtermCore && swift test --filter AttentionCounts` — must pass before task 2

### Task 2: AppStore.attentionCounts accessor

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Status.swift` (add `attentionCounts` directly
  after the `attentionSessions` computed property, reusing it rather than re-deriving its filter)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift` (add cases beside the existing
  `controlTreeReportsStatusPaneForNonIdleSession` status tests)

- [x] write a failing test: a store with non-idle sessions spread across two workspaces counts all
      of them, proving the accessor inherits `attentionSessions`' cross-workspace reach
- [x] write a failing test: `activeUnseen` is the selected session's `unseenCount` alone, not a sum
      across sessions
- [x] write a failing test: no selected session reads as zero unseen rather than crashing
- [x] add the `attentionCounts` computed property built from `attentionSessions` and `activeSession`
- [x] run `cd agtermCore && swift test --filter AttentionCounts` — must pass before task 3
      (the new AppStore cases are named lowercase, so `--filter attentionCounts` runs them; both ran green)

### Task 3: The pill view

**Files:**
- Create: `agterm/Views/WindowContentView+AttentionPill.swift`
- Create: `agtermTests/AttentionPillTests.swift`
- Modify: `agterm/Views/WindowContentView+Titlebar.swift` (add the pill inside the `HStack` in
  `chromePills`, after `overlayRedirectPill` — one line, nothing else in this file)

- [x] write failing tests in `AttentionPillTests`, modelled on
      `agtermTests/OverlayRedirectPillTests.swift`: drive the static state function directly,
      covering the all-zero case (no segments), exactly one non-zero category, and all four
- [x] create `WindowContentView+AttentionPill.swift` with the segment table (category → symbol →
      color → count), the static state function taking `AttentionCounts`, and the capsule view
      following `overlayRedirectPill`'s shape and caption sizing
- [x] render nothing at all when `counts.isEmpty`; omit any segment whose count is zero
- [x] add the accessibility identifier `attention-counts-pill` and expose the counts through
      `.accessibilityValue`
- [x] add the one line to `chromePills`; do NOT modify `floatingPillsLayer`, its
      `allowsHitTesting(false)`, or either `sidebarOnScreen` gate
- [x] verify each SF Symbol resolves at the deployment target; substitute a near neighbour if one
      does not, and note the substitution in this plan
- [x] run `./scripts/test-app.sh -only-testing:agtermTests/AttentionPillTests` — must pass before
      task 4

### Task 4: Document the pill as fork-only chrome

**Files:**
- Modify: `.claude/rules/notifications.md` (the `Titlebar attention` section)

**Model:** haiku

⚠️ Scope change: the entry went to `.claude/rules/notifications.md`, not `libghostty.md` or
`menu-actions.md`. `notifications.md` already owns `attentionSessions`, the bell and the sentence
`There is no count or pulse`, so the pill belongs beside the thing it answers. Both of the traps the
plan asked to record are already stated in `libghostty.md`; per the own-a-contract-once rule the new
entry cross-references `[[libghostty]]` for them rather than restating them.

- [x] add a short entry: what the pill shows, that it is informational and not clickable, that it
      rides `chromePills` and therefore `sidebarOnScreen`, and that it deliberately does not follow
      the `StatusShape` setting
- [x] record the two traps for a future reader: `allowsHitTesting(false)` on `floatingPillsLayer` is
      load-bearing, and `sidebarVisible` is the wrong predicate
      (cross-referenced to `[[libghostty]]`, which already states both, instead of a second copy)
- [x] record that the message count is deferred and why
- [x] confirm nothing was added to `plugins/agterm/skills/agterm/`, `site/commands.html`,
      `README.md` or `CHANGELOG.md` (`git diff --name-only main...HEAD` lists none of them)

### Task 5: Verify acceptance criteria

➕ Scope addition: the three `attentionCounts` cases task 2 added to `AppStoreTests.swift` pushed that
file from 1995 to 2034 lines, over its 2000-line test limit. Per the "put new logic in a new file
instead" rule they moved to a new `AppStoreAttentionCountsTests.swift`; the limit was not raised.

⚠️ `make lint` does not reach zero findings, and this branch is not the cause.
`agtermCore/Sources/agtermCore/AppStore.swift` (1060 lines) and `ControlDispatcher.swift` (1070) both
break the 1000-line source limit. Both are byte-identical to `main`, the lint config is unchanged, and
both arrived with the upstream merge `54b9835`, so `main` fails lint the same way. Splitting a file
nothing here touched needs Sasha's approval per CLAUDE.md, so they are left alone and reported.

- [x] verify all requirements from Overview are implemented
- [x] verify the empty case renders no pill, and a single non-zero category renders one segment
      (`testNoSegmentsWhenEverythingIsZero`, `testASingleNonZeroCategoryRendersOneSegment`)
- [x] verify nothing in `floatingPillsLayer` changed: `git diff` on
      `agterm/Views/WindowContentView.swift` is empty
- [x] verify the diff touches no upstream-facing surface: `git diff --name-only` lists nothing under
      `plugins/`, `site/`, `README.md` or `CHANGELOG.md`
- [x] run `cd agtermCore && swift test` — 2977 tests in 113 suites, green
- [x] run `make build` — BUILD SUCCEEDED
- [x] run `make test-app` — 354 tests, 4 skipped, 0 failures
- [x] run `make lint` — the branch's own findings are zero; the two preexisting violations above remain

### Task 6: [Final] Update documentation

- [ ] update `CLAUDE.md` only if a genuinely new pattern was discovered; do not restate the plan
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention — no checkboxes, informational only*

**Manual verification** (Sasha's, by hand, after the branch lands):
- the pill reads clearly in the sidebar footer and floating bottom-right over the terminal
- the four glyphs are distinguishable at caption size without relying on color
- the colors track Settings when the status colors are changed
- the pill does not intercept clicks anywhere in the window

**Follow-up work, not part of this run:**
- the fifth segment for new peer messages, once the peer-messaging brainstorm settles how a message
  announces itself and what control command carries the count
