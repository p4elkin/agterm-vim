# Session recency read-back on the control tree

## Overview

`agtermctl tree --json` reports no session recency, so nothing outside the app can tell which
session you were on before this one. The order exists already: `AppStore.sessionRecency`
(`agtermCore/Sources/agtermCore/AppStore.swift:97`) is a per-window `RecencyStack<UUID>` backing
the Ctrl-Tab switcher, the title-bar recent popover, the Dock menu and `dashboard --mru`. It is
persisted per window and pruned of stale ids on restore, but it is app-internal.

This adds one optional top-level tree field, `sessionRecency`: session ids as strings, most
recent first, omitted when empty. It carries the same list the title-bar popover shows — the
currently active session is dropped, and the visible navigation scope applies — so a consumer
reads jump targets, not raw state.

The payoff outside this repo is a picker script that shows the last few sessions and jumps to the
one you choose. That script and its key binding live in `~/.local/bin` and
`~/.config/agterm/keymap.conf`, outside this repository, and are NOT part of this plan.

Approved design: `~/.claude/plans/polished-bubbling-yao.md`.

## Context (from discovery)

- Files involved: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (the `ControlTree` type),
  `AppStore.swift` (`controlTree(...)`), `AppStore+Recency.swift` (the two existing read helpers).
- Related patterns found: `dashboardMembers` / `dashboardHighlighted` are the model for an
  optional top-level tree field. They reach `controlTree` through a `() -> T?` closure because the
  value lives in an app-side dashboard controller. Recency does not need that — it is store state,
  and `AppStore` builds the tree, so the value is computed in place.
- `ControlTree` has no `CodingKeys`; `Codable` synthesis omits a nil optional automatically.
- Dependencies identified: none. The change is host-free `agtermCore` only. `ControlServer` is
  untouched, so `swift test` is the real gate.
- Target branch: off `vimfork/main` (`git@github.com:p4elkin/agterm-vim.git`), NOT `origin/master`.
  That fork carries the normal mode this feature is ultimately for.

## Development Approach

- **parallel waves**: none - task 2 wires the field that task 1 declares, and task 3 documents it,
  so each task needs the one before it to compile.
- **testing approach**: Regular (code first, then tests inside the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- run the narrow per-task command after each change; the full gates run once in the verify task
- maintain backward compatibility: the field is optional and absent from every existing response
  shape, so an older consumer sees no change

## Testing Strategy

- **unit tests**: required per task, in `agtermCore/Tests/agtermCoreTests/`
- **e2e tests**: not needed. This project's end-to-end layer is XCUITest, which is slow and tells
  you nothing a host-free test does not for a Codable projection. `agtermUITests/DashboardUITests.swift` (its
  `dashMembers()` helper) shows the socket read pattern if one is ever wanted.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep this plan in sync with the actual work

## Solution Overview

Reuse `navigableRecentSessions(limit:)` rather than writing new filtering. It already returns
most-recent-first ids, narrowed to `navigableSessions` and with the active session removed, and it
already backs the popover and Dock menu. One thin wrapper turns it into the wire shape.

Chosen deliberately over the raw `recentSessions(limit:)` (which keeps the active session and
ignores the workspace filter): the field is meant to answer "where can I jump back to", and the
tree already reports `active` per session for anything else.

The limit passed is the stack's own bound, so the field carries every live candidate and each
consumer picks its own count.

## Technical Details

- Wire shape: `"sessionRecency": ["<UUID>", "<UUID>", ...]`, most recent first, key absent when
  the list is empty. Ids are `uuidString`, uppercase, matching the `id` fields already in the tree.
- A session that was never selected has no entry, so the array can be shorter than the session
  count. Tree order remains the fallback for a complete list.
- Per window: `tree` resolves one window's store, and recency is per-window state.

## What Goes Where

- **Implementation Steps**: the field, its tests, and the bundled skill docs in this repository.
- **Post-Completion**: the deploy, the picker script, the keymap binding, and the upstream issue.

## Implementation Steps

### Task 1: Declare the sessionRecency field on ControlTree

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (the `ControlTree` struct: add the property beside `dashboardHighlighted`, and add the parameter and assignment to its custom `init`)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift` (beside `treeRoundTripsWithDashboardFields` and `treeOmitsDashboardFieldsWhenNil`)

- [x] add `public let sessionRecency: [String]?` to `ControlTree`, next to the dashboard fields and before `pickPending`
- [x] add `sessionRecency: [String]? = nil` to the custom init signature and assign it in the body, keeping the existing parameter order convention
- [x] write a round-trip test asserting a populated value survives encode and decode
- [x] write a test asserting the key is absent from the encoded JSON when nil, and decodes back to nil
- [x] run `cd agtermCore && swift test --filter ControlProtocolTests` - must pass before task 2

### Task 2: Populate the field from the window's recency stack

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Recency.swift` (add `controlSessionRecency()` beside `navigableRecentSessions(limit:)`)
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the `ControlTree(...)` construction at the end of `controlTree(...)`)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift` (beside the existing `controlTreeReportsDashboardFieldsFromClosures` block)

- [x] add `controlSessionRecency() -> [String]?` returning `navigableRecentSessions(limit: sessionRecency.limit)` mapped to `uuidString`, and nil when empty
- [x] pass `sessionRecency: controlSessionRecency()` in the `ControlTree(...)` construction; do NOT add a closure parameter to `controlTree(...)`, the value is store state
- [x] write a test that selects a then b and asserts the tree lists a and omits b, because b is active
- [x] write a test asserting most-recent-first order across three selections
- [x] write tests for the empty cases: a store with a single session omits the field, and a closed session never appears
- [x] run `cd agtermCore && swift test --filter AppStoreTests` - must pass before task 3

### Task 3: Document the field in the bundled skill

**Files:**
- Modify: `plugins/agterm/skills/agterm/reference.md` (the paragraph opening "The tree object itself carries twelve top-level read-only fields")
- Modify: `plugins/agterm/skills/agterm/SKILL.md` (the sentence "The tree object also carries five read-only top-level fields")
- Modify: `plugins/agterm/skills/agterm/examples.md` (the jq query reading `{dashboardMembers, dashboardHighlighted, dashboardFontSize, dashboardFontMode}`)
- Modify: `.claude/rules/control-api.md` (the bullet opening "Top-level tree includes idle/auto-follow" in the `## Tree and window read-back` section)

- [x] add `sessionRecency` to the reference.md catalog, describing the dropped active session and the visible-scope narrowing, and change both "twelve" mentions to "thirteen"
- [x] correct the SKILL.md sentence: it claims five fields and lists five while thirteen exist, so list them all and give the honest count
- [x] add `sessionRecency` to the examples.md jq object query, and add a one-line example that jumps to the previous session
      ⚠️ deviation: the only jq object query in examples.md is the dashboard read-back
      (`{dashboardMembers, dashboardHighlighted, ...}`). `sessionRecency` is not dashboard state, so
      putting it there would document it wrongly. It got its own "Jump back to the session you were on
      before" section instead, with the read-back and the jump one-liner.
- [x] add a line to `.claude/rules/control-api.md` recording that `site/commands.html` still claims seven top-level fields, lists seven of thirteen, and is deliberately not fixed on this fork
- [x] run `cd agtermCore && swift test --filter SkillInstallTests` - must pass before task 4

### Task 4: Verify acceptance criteria

- [ ] verify `tree --json` carries `sessionRecency` when a window has a previous session, and omits it otherwise
- [ ] verify the active session never appears in the array
- [ ] run full host-free suite: `cd agtermCore && swift test`
- [ ] run `make lint` - zero findings required
- [ ] run `make test-app`

### Task 5: [Final] Update documentation

- [ ] confirm no other in-repo surface names the tree top-level fields exhaustively
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- Build and deploy the fork, then restart agterm. The field does not exist in the running app until
  then. The user decides when to restart; every live session lives in that process.
- After restart: `agtermctl tree --json | jq '.result.tree.sessionRecency'` on the live socket, which
  is a read-only call and therefore safe.

**External system updates:**
- `~/.local/bin/agterm-session-list.py` gains a `--recent N` mode reading this field (default 6).
- `~/.local/bin/agterm-recent-picker.sh`, a sibling of `agterm-session-picker.sh`.
- `~/.config/agterm/keymap.conf`: a `command "Recent sessions"` opening that picker in an overlay,
  bound to bare `tab` in normal mode, and `nmap f "FZF Files"` restored.
- Upstream issue on umputun/agterm about the stale field counts in `site/commands.html` and
  `SKILL.md`. Tracked as a session todo.
