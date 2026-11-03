# zmx attach --parent: attach a remote session as a companion of a row here

Status: written with a Fable talk pair (`Pair: attach-parent`, review msg-004425-4b6b), revised after
`planning:plan-review` round 1.
Size: M (three app-target files, four agtermCore files, CLI, tests, five doc surfaces).
Review: round 2 findings folded in.

## Contents

- [Goal](#goal)
- [Why nothing works today](#why-nothing-works-today)
- [Design](#design)
- [Tasks](#tasks)
- [Using it on the nine rows](#using-it-on-the-nine-rows)
- [Gates](#gates)

## Goal

Sasha wants nine lab rows from p4linux's headless agterm to become companions of the row `walker-scenarios` on
this Mac (p4studio). `walker-scenarios` is itself a p4linux remote row here (`remoteHost: p4linux`), like the nine.
Each row runs a live Claude session that must keep its transcript, and nothing on p4linux may change.

## Why nothing works today

- `Session.parentID` is `internal(set)`: set only by `AppStore.addSession` and by snapshot restore.
- `attachRemoteSession` in `agterm/Control/ControlServer+Zmx.swift` puts an attached row under a parent only when
  the origin's `zmx tree` reports `parent` (through `attachedParentRows`). A headless origin never does:
  `HeadlessActions` refuses every companion command and its model has no parent.
- `RemoteRowBook.Record` (`remote-rows.json`) has no parent, so a relaunch restores every remote row top-level.

The placement itself exists: `RemotePlacement.parent`, used by `zmx attach --companions` through `attachMember`
in `ControlServer+RemoteGroup.swift`, and `attach(_:from:host:placement:)` already answers `result.parent`.
What is missing is a way for the caller to name the parent.

## Design

### The argument

`agtermctl zmx attach HOST SESSION --parent ROW`.

- Wire: a new optional `ControlArgs.parent`. The request target stays the remote session. `args.attach` is not
  reused, because `--beside` and `ForwardPolicy.route` already key on it.
- `ROW` resolves like any session target, across every open window (`ControlTargetResolver.resolveSession` with no
  window). A companion `ROW` means its parent, as `companionSlot` does with `parent(of:) ?? target`.
- The row lands in `ROW`'s window and workspace, over `ROW`'s transport.
- Refusals, each by name, enforced in the DISPATCHER (the CLI repeats the flag-combination ones in `validate`
  for a clear usage error):
  - `parent` with `window`, `transport`, `moshServer`, `mosh` or `attach` (`--beside`). The `parent` guards go
    ABOVE the existing `attach` guard in `ControlDispatcher+Zmx.swift`, whose text would otherwise win.
  - `parent` on `zmx.attach.group` (`--companions`).
  - `parent` that fails `RemoteSession.isPlain`, since an unresolved ROW is echoed in the error.
  - in the server: `ROW` is not a remote row of `HOST` with the same zmx endpoint; a local `ROW` is refused
    because the saved record can only name a remote parent.
  - `ROW` is a page companion; the remote session is a page, or the origin reports a different parent for it.
- A headless origin hands a `--beside` request to the forwarder before any dispatcher runs
  (`HeadlessActions.respond`), and the Mac answers it in `ControlServer+Forward.swift` through `attachBeside`.
  That branch refuses `args.parent` too, or a raw client gets `ok` with the parent ignored.
- No "already has a row here" guard: attaching the new row before closing the old one must work.
- `ControlActions`: a new overload beside the existing `attachRemoteSession` requirements, with a
  `ControlActionsDefaults` default that refuses `--parent` by name. `HeadlessActions` refuses it explicitly,
  since a defaulted requirement compiles silently there (fork-merge.md). `ForwardPolicy` needs no change:
  `attach == nil` already yields "a Mac feature".
- `HtmlBridge` lists `.zmxAttach` in `placedLocally` and fills `args.window` from the page. It skips that fill
  when `args.parent` is set, or every page-issued `--parent` would be refused.
- Read-back: the tree session node's `parent` field, already projected, and the reply's `result.parent`.
  An app built before this change drops the unknown key and attaches top-level with `ok: true`, so the CLI fails
  with `the running app is too old for --parent; attached <id> as a top-level row` when it sent `--parent` and the
  reply has no `result.parent`, exiting 1. The row exists by then, so the message names it for closing; `--json`
  prints the raw reply and exits 1 the same way.

Consumers of `ControlArgs.parent` (10): CLI `validate`, CLI request building, dispatcher `.zmxAttach`, dispatcher
`.zmxAttachGroup` refusal, the `ControlActions` requirement, its `ControlActionsDefaults` default, the
`ControlServer` conformance, `HeadlessActions`, `HtmlBridge`, the `--beside` branch of `ControlServer+Forward.swift`. `ForwardPolicy` was checked and needs no change.

### The saved parent

- `RemoteRowBook.Record` gains `parentRemoteSessionID: String?`. Synthesized `Codable` already decodes a missing
  optional key as nil, so older files load with no custom decoder. The host is the record's own `host`.
- `Record.init?(session:...)` gains a defaulted parameter for it (the type is public; `agterm-linux` consumes
  `agtermCore`). `records(in:)` fills it by looking `session.parentID` up in the same workspace's rows and reading
  `remotePresentation?.binding.remoteSessionID`.
- A saved parent id that fails `RemoteSession.isPlain` is treated as nil, not as an invalid record: `load()`
  discards invalid records, and a row is never dropped for its parent.
- Restore resolves the parent inside the `restoreRemoteRows` loop, after earlier rows were inserted. It matches
  exactly one top-level row in the entry's own workspace with the same host, endpoint and remoteSessionID, as
  `attachedParentRows` does, and passes it as `RemotePlacement.parent`. `addSession` sets `parentID` even when the
  parent is in another workspace, so the workspace check is what prevents a dangling link. No match, or more than
  one, leaves the companion top-level, as
  `regroupedCompanions` does.
- Restore keeps the saved order. A companion whose parent is not restored yet waits for a second pass, and the rows
  after it in its workspace move up by one: `records(in:)` saves a soft-closed companion at its old index, which can
  sort it ahead of its parent (Task 3 review, then revmux round 1). The deferred companion's position only matters
  within its group, where `insertionIndex(for:near:in:)` clamps it.
- Two rows of one remote session (the old top-level row and its new companion row) are a transient state:
  restore keeps one row per (host, remoteSessionID), so the old row must be closed before a relaunch.

## Tasks

Each task is test-first. Its Check must pass before the next task starts.

### Task 1: saved parent in `RemoteRowBook.Record` (agtermCore)

- [ ] Tests in `agtermCore/Tests/agtermCoreTests/RemoteRowBookTests.swift`: round trip with a parent; an old file
      without the key loads with nil; a control character in the parent id loads the record with nil; a
      companion row's record names its parent's remote id.
- [ ] Field, defaulted init parameter, `records(in:)` fill, the `isPlain` sanitizing on load.

Check: `cd agtermCore && swift test --filter RemoteRowBookTests`

### Task 2: `ControlArgs.parent`, dispatcher, CLI, bridge (agtermCore)

- [ ] Tests: dispatcher routing of `parent` and every dispatcher refusal (`ControlDispatcherZmxTests`); CLI parse,
      `validate` refusals and the too-old-app failure (`ZmxCommandsTests`); the headless refusal
      (`HeadlessActionsTests`); the bridge leaving `window` unset when `parent` is set (the `HtmlBridge` tests).
- [ ] `ControlArgs.parent`, the dispatcher branch, the `ControlActions` overload and default, `HeadlessActions`,
      `ZmxCommands.swift` `--parent`, `HtmlBridge`.

Check: `cd agtermCore && swift test --filter 'ControlDispatcherZmxTests|ZmxCommandsTests|HeadlessActionsTests|HtmlBridge'`

### Task 3: server attach under `ROW` and restore under the saved parent (app target)

depends: 1, 2

- [ ] Tests in `agtermTests/ControlServerZmxTests.swift`, beside
      `testACompanionAttachedAloneJoinsItsAttachedParentInThatParentsWorkspace` and reusing its fixtures: the `ROW`
      refusals (local row, other host, other endpoint, page companion), a page remote session, an origin that
      reports a different parent; a companion `ROW` resolves to its parent; a `ROW` in a background window lands
      the row in that window; attaching a remote session that already has a top-level row here leaves two bound
      rows, the new one under `ROW`.
- [ ] Test in `agtermTests/ControlServerZmxTests.swift`, beside
      `testAForwardedAttachBesidePlacesTheSessionAfterTheRowFromItsOwnHostUnselected`: a forwarded `--beside` with
      `parent` is refused.
- [ ] Tests in `agtermTests/RemoteRowRestoreTests.swift`: [parent, companion] records restore the companion under
      the parent; a missing or ambiguous parent, or one in another workspace, restores it top-level.
- [ ] The `attachRemoteSession` overload with a parent, the `--beside` refusal, and the restore placement.

Check: `scripts/test-app.sh -only-testing:agtermTests/ControlServerZmxTests -only-testing:agtermTests/RemoteRowRestoreTests`
(the worktree's six ignored artifacts are symlinked only while their stamps match, so the script's setup step
builds nothing).

### Task 4: docs

- [ ] `plugins/agterm/skills/agterm/reference.md`: `--parent` in the `zmx attach` entry and in the companions
      paragraph; `SKILL.md` gets a pointer in its remote-attach section.
- [ ] `.claude/rules/control-api.md`: add the parent to the Remote sessions bullet starting "A remote row is saved
      OUTSIDE the snapshot", and name `--parent` where that section covers attach.
- [ ] Stale "a remote session is never restored / never written to disk" claims: `reference.md` (the session-node
      description, the `zmx attach` close paragraph, and "its own tint is not persisted, like the row"), `SKILL.md`, and the `zmx attach` help text in
      `ZmxCommands.swift`. `upstream/master` still carries the reference.md text, so this edit will conflict on
      merges; note it in `fork-merge.md`'s colliding-files list.
- [ ] `FORK-NOTES.md` (pointing at control-api.md) and `CHANGELOG-fork.md` under `## Unreleased`.
- Not `site/commands.html`: fork-only additions such as `--beside` stay out of it.

Check: `make lint` (covers the help-text change; the docs have no automated check, so the reviewer reads them).

## Using it on the nine rows

Each step only with Sasha's yes. After `make deploy`, Sasha restarts the Mac app once.

1. Read `walker-scenarios`' current Mac id from `agtermctl tree --json` (it may change on restart).
2. Per row, one row first: `agtermctl zmx attach p4linux <p4linux id> --parent <walker id>`.
3. Check the new row is under `walker-scenarios` (`parent` in the tree) and that its screen shows the same Claude
   conversation as the old row.
4. Close the old Mac row. It is a detach only: a remote row owns no local pane identity, so no daemon is killed.

The attach takes the zmx lead (`claim: true`). Two clients on one daemon is what
`scripts/zmx-patches/0001-explicit-leadership.patch` exists for.

⚠️ No app restart while any old row is still open, or within 3 s of closing one (the soft-close grace keeps it in
the book). Restore keeps one record per (host, remoteSessionID), whichever sorts first, and may bring back the old
top-level row instead of the companion.

Verify: `agtermctl tree --json` shows `parent` = walker-scenarios' id on each of the nine rows.

Closing `walker-scenarios` afterwards closes the nine Mac rows too (detach only); one undo restores the group.

## Gates

`cd agtermCore && swift test`, `make test-app`, `make lint`, each once at the end. The pair works off local `main`, which carries the
10-31 upstream merge (#847-#850) once its own gates are green.

Not flagged in `fork-merge.md`: Sasha declined adding `ControlServer+Zmx.swift` to `flagged` (2026-11-03).

<!-- plan-review: planning:plan-review 2026-11-03 findings=22 resolved -->
