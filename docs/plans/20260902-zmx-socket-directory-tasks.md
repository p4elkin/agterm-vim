# Put the zmx socket directory on the control API

## Overview

`agtermctl zmx list` reports which daemons exist and who owns them, but not the directory they live in.
That directory is `/tmp/agterm-zmx-<16 hex>`, an FNV-1a hash of the resolved state directory, computed
in `ZmxSupport.socketDirectory(forStateDirectory:)` and used only inside the app. An outside script
that wants to run `zmx attach` against one of those daemons has to reimplement the hash.

This adds `socketDirectory` to `zmx list`'s payload so the script reads the value the app is actually
using.

⚠️ Reimplementing the hash is not merely duplicated work, it is wrong in a way that stays silent.
`ZmxSupport.socketDirectory` hashes the path after `standardizedFileURL` and `resolvingSymlinksInPath`,
and Foundation's pair of those strips the `/private` prefix. For state directory `/tmp/agz` the app
uses `/tmp/agterm-zmx-e37fc371e9dbafce`, the hash of `/tmp/agz`, while a caller reaching for the same
answer through `realpath()` gets `/private/tmp/agz` and so `/tmp/agterm-zmx-9055e82a79b3ad66`. That
second directory does not hold the daemon, and `zmx list` there does not fail — it creates the
directory and answers "no sessions found". The caller reports a healthy empty namespace while every
pane runs next door. Measured during the rehearsal by making exactly that mistake.

The design record is `docs/plans/20260901-zmx-adopt-upstream-agent-scripts.md`. This file is only the
executable half of its section 3. Read that document for why the field goes on `ControlZmxInventory`
rather than on `ControlRestoreStatus`, and which surfaces the cross-surface contract reaches.

⚠️ Scope stops at the end of this file. Section 4 of the design record (the migration of the live
namespace) is done by hand by the maintainer. Section 5 (repairing the scripts in
`~/dev/agterm-agents`) is a different repository and a separate run. Do not start either.

## Context (from discovery)

- `agtermCore/Sources/agtermCore/ControlPayloads.swift` — holds `ControlZmxInventory` and
  `ControlRestoreStatus`, the nested `ControlResult` payloads
- `agtermCore/Sources/agtermctlKit/SocketClient.swift:267` — `formatZmx`, the human rendering
- `agterm/Ghostty/ZmxClient.swift` — holds `private let socketDirectory`, the value to report
- `agterm/Control/ControlServer+Zmx.swift:13` — `listZmxDaemons()`, which already holds that client
- `agtermCore/Sources/agtermCore/ZmxSupport.swift` — where the directory is computed; not changed here
- `agterm/Control/ControlServer.swift:557` — `restoreStatus()`, the rejected alternative home

## Development Approach

- **testing approach**: TDD. Each task writes its failing test first, then the code that passes it.
- complete each task fully before moving to the next
- every task's last checkbox is that task's own narrow test command; it must pass before the next task
- the four wide gates run ONCE, in the last task, never per task
- keep this file in sync: mark `[x]` immediately, `➕` for discovered tasks, `⚠️` for blockers

## Repository constraints that bind every task

- ⚠️ NEVER run `agterm` or `agtermctl` against the default socket, never launch or quit the app.
  Static reading and building only. Verify through tests.
- `agtermCore` is host-free: no GhosttyKit, AppKit, Metal or CoreGraphics, and no CoreGraphics
  geometry types.
- ⚠️ `agtermCore` is a `.library` product the `agterm-linux` fork consumes, so a public initializer
  with a new required parameter is a source break for any construction site outside this repository.
  Task 1 checks that clone before landing rather than assuming.
- `GhosttyKit.xcframework`, `agterm/Resources/ghostty` and `agterm/Resources/terminfo` are symlinks
  into the main checkout. Do not delete or rebuild them, and do not run `scripts/setup.sh`.

## Implementation Steps

### Task 1: Socket directory on the zmx list payload

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Create or modify: a test file under `agtermCore/Tests/agtermCoreTests/` covering `ControlPayloads`

- [ ] write the failing test `theSocketDirectoryRidesTheInventorySoAnOutsideAttachCanFindIt`: encode a
      `ControlZmxInventory` and assert the wire key `socketDirectory` holds the value passed in
- [ ] write the failing test `anOlderServerOmittingTheDirectoryStillDecodes`: decode a hand-written
      JSON object with no `socketDirectory` key, expect the field nil and the rest of the payload intact
- [ ] add `public let socketDirectory: String?` to `ControlZmxInventory`
- [ ] add `socketDirectory: String` to its initializer, last, with no default
- [ ] check the `agterm-linux` clone for another construction site of `ControlZmxInventory` before
      landing the required parameter; if one exists, note it here with `⚠️` and give the parameter a
      default instead
- [ ] run tests - must pass before task 2: `cd agtermCore && swift test --filter theSocketDirectoryRidesTheInventorySoAnOutsideAttachCanFindIt`

### Task 2: The CLI prints it

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/ZmxCommandsTests.swift`

- [ ] write the failing test `theDirectoryIsPrintedBecauseAttachingFromOutsideNeedsIt` asserting
      `formatZmx` output contains the directory
- [ ] add a second assertion in that test: a nil directory prints no line rather than an empty one
- [ ] extend `SocketClient.formatZmx`, putting the directory in the header block with the restore
      status and before the rows, because it describes the whole listing and not one daemon
- [ ] run tests - must pass before task 3: `cd agtermCore && swift test --filter ZmxCommandsTests`

### Task 3: The app fills it from the client it already holds

**Files:**
- Modify: `agterm/Ghostty/ZmxClient.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [ ] write the failing test `testListReportsTheSocketDirectoryTheClientIsUsing` in
      `agtermTests/ControlServerZmxTests.swift`; the existing `makeServer(runner:)` helper at line 508
      builds its `ZmxClient` with `socketDirectory: "/tmp/zmx-dir"`, so assert
      `XCTAssertEqual(inventory.socketDirectory, "/tmp/zmx-dir")`
- [ ] drop `private` from `ZmxClient.socketDirectory`
- [ ] pass `client.socketDirectory` in `listZmxDaemons()`; read the value the app is using, do not
      recompute the hash in a second place
- [ ] run tests - must pass before task 4: `xcodebuild -project agterm.xcodeproj -scheme agterm -configuration Debug -destination 'platform=macOS' test -only-testing:agtermTests/ControlServerZmxTests/testListReportsTheSocketDirectoryTheClientIsUsing`

### Task 4: The documentation mirrors

**Files:**
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/examples.md`
- Modify: `site/commands.html`

- [ ] `reference.md`, the `zmx list` paragraph at line 1420: one sentence saying the listing names the
      socket directory the daemons live in, and that `ZMX_DIR` must carry it for a plain shell or a
      mosh session to reach them
- [ ] `SKILL.md` at line 606: one clause
- [ ] `examples.md` at line 43: a worked example reading the directory and a daemon name out of one
      `--json` call and attaching — that example is the reason the field exists
- [ ] `site/commands.html`, the `zmx list` entry at line 2843: matching wording
- [ ] state no command total anywhere; `.claude/rules/control-api.md` forbids it and this adds no command
- [ ] run tests - must pass before task 5: `cd agtermCore && swift test --filter SkillInstallTests`

### Task 5: The two fork docs, in the same commit as the code

**Files:**
- Modify: `FORK-NOTES.md`
- Modify: `CHANGELOG-fork.md`

- [ ] `FORK-NOTES.md`: one line under **Control API and tooling** at line 62, beside the
      `sessionRecency` line
- [ ] `CHANGELOG-fork.md`: a user-facing entry under `## Unreleased` → `### Improved`, saying what it
      is for — an outside script reads the directory instead of reimplementing the hash
- [ ] in the commit message, record why no `.claude/rules/fork-merge.md` entry is needed: a merge
      resolution that took upstream's `ControlPayloads.swift` whole would fail `swift test` on both new
      core tests and the CLI test, and `make test-app` on the app test, so the behaviour is not
      invisible to the gates
- [ ] run tests - must pass before task 6: `cd agtermCore && swift test --filter ControlPayloads`

### Task 6: Verify acceptance criteria

- [ ] verify `socketDirectory` is optional on the wire and required in the producer's initializer
- [ ] verify a payload with no `socketDirectory` key still decodes, with the rest intact
- [ ] verify `formatZmx` prints the directory in the header and prints nothing for a nil one
- [ ] verify `listZmxDaemons()` reports the client's own value rather than a recomputed hash
- [ ] verify `ControlTree` was not touched, so `SkillInstallTests`' field count of 16 still holds
- [ ] run the full host-free suite: `cd agtermCore && swift test`
- [ ] run lint, zero findings required: `make lint`
- [ ] run the Release build: `make release`
- [ ] ⚠️ run the hosted tests: `make test-app` — the only one of the four that compiles `agtermTests`,
      where task 3's test lives, so skipping it leaves the test that proves the field is populated
      uncompiled

### Task 7: [Final] Update documentation

- [ ] confirm `FORK-NOTES.md` and `CHANGELOG-fork.md` both carry the feature, per
      `.claude/rules/release.md`
- [ ] confirm `.claude/rules/control-api.md` needs no change; this adds a read-back field to an
      existing command and states no total
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Maintainer's own steps, in order, from section 4 of the design record:**

- take stock of the live namespace, then `agterm-park park-all` on the OLD build, then read the
  park-all report before going further
- quit agterm, clear the old namespace, write `"restoreMode": "live"` into `settings.json` while the
  app is down, then `make deploy` and launch once

**Separate run, different repository:**

- section 5 of the design record repairs `agterm-zmx`, `agterm-zmx-status`, `agterm-zmx-mirror` and
  `agterm-zmx-test` in a clone of `~/dev/agterm-agents`, and deletes `agterm-zmx-sync`,
  `agterm-zmx-retire` and the zprofile hook. ⚠️ `~/.local/bin/agterm-zmx*` symlink into that repo's
  `bin/`, so an edit in the maintainer's own checkout is live immediately — that work belongs in a
  clone, not here.
