# Remove mosh from the fork

<!-- plan-review: planning:plan-review 2026-11-23 findings=21 resolved -->

## Contents

- [Overview](#overview)
- [Decisions](#decisions)
- [Context](#context)
- [Development approach](#development-approach)
- [Design](#design)
- [Implementation steps](#implementation-steps)
- [Post-completion](#post-completion)

## Overview

The fork added a mosh transport to remote attach (`zmx attach --transport mosh`).
Upstream `umputun/agterm` has no mosh at all.
This plan removes every mosh code path, flag, test and current-behaviour doc from agterm-vim, and the
agterm-agents scripts that build or parse mosh commands.
Every remote attach is ssh afterwards.

Measured 2026-11-23 on p4studio: 92 saved remote rows, all ssh; 132 rows in 12 open windows, none running mosh;
no saved window state mentions mosh.
The one live producer is `agterm-attach-picker` on a laptop, which attaches p4studio claude and shell rows over
mosh. Those rows attach over ssh after this change.

## Decisions

Approved by Sasha in the brainstorm, 2026-11-23.

- Remove all of it. Laptop rows reconnect over ssh after sleep instead of roaming.
- A saved mosh record in `remote-rows.json` is dropped at load with one log line. ssh records in the same file still load.
- No rollback constant: new builds write no `transport` key. An older fork build reading the new file loads
  zero remote rows. Accepted.
- `agtermctl zmx attach --transport/--mosh-server/--mosh` and the protocol fields `transport`, `moshServer`,
  `mosh` are removed, not kept as an ssh no-op.
- agterm-agents `rooms/rooms_pane.py` far-pane guard (`_far_block`), which recognises only mosh, is deleted.
- Dated plans under `docs/plans/` are history and keep their mosh mentions.
- `CHANGELOG-fork.md` has only an `## Unreleased` section. Its existing mosh entries stay as the record of what
  shipped to the fork's users, and a new entry under `Unreleased` records the removal.

## Context

agterm-vim, every file using the transport symbols (`RemoteTransport`, `.transport` on an origin, row or record,
`moshServer`, `isPlainMoshServer`, `moshCandidates`) — 16 sources (one comment-only) and 13 test files (two comment-only):

- `agtermCore/Sources/agtermCore/`: `RemoteSession.swift`, `RemoteRowBook.swift`, `RemotePresentationState.swift`,
  `ControlActions.swift`, `ControlActionsDefaults.swift`, `ControlDispatcher+Zmx.swift`, `ControlProtocol.swift`,
  `SshHostPools.swift`, `AppStore+AttachedRestore.swift`
- `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`, `agtermCore/Sources/AgtermHeadlessKit/HeadlessActions.swift`
- `agterm/Control/`: `ControlServer+Zmx.swift`, `ControlServer+AttachedForward.swift`, `ControlServer+HostPools.swift`,
  `ControlServer+RemoteRows.swift`; comment only in `agterm/Ghostty/PaneLead.swift`
- tests: `ControlDispatcherZmxTests`, `MockControlActions`, `RemotePresentationStateTests`, `RemoteRowBookTests`,
  `RemoteSessionTests`, `SshHostPoolsTests`, `WindowLibraryTransferTests`, `ZmxCommandsTests`, `OverlayRedirectSshTests` (comment);
  hosted `ControlServerHostPoolTests`, `ControlServerZmxTests`, `RemoteRowRestoreTests`, `CustomCommandRunnerTests` (comment)

`RemoteRowBook.load` decodes the whole file with one `try?`: one undecodable record empties the book.
`RemoteRowBook.Record` uses synthesized `Codable`; `RemoteBinding.Origin` is not `Codable`, so the book is the
only persisted carrier of a transport.
`CoreLog` is agtermCore's logger and works on Linux.

agterm-agents (`origin/main`): 2 producers (`bin/agterm-attach-picker`, `bin/agterm-headless-switch-rows`),
6 parsers (those two plus `bin/agterm-open-path`, `bin/agterm-open-link`, `rooms/rooms-deliver.py`,
`rooms/rooms_pane.py`), 5 test modules and 4 fixtures that cover them, about 22 prose-only files, and current-behaviour
docs under `docs/claude/`.
Every parser except `rooms_pane.py` already has an ssh branch beside its mosh one.

## Development approach

- TDD for the old-record load path: the failing mixed-file test comes first, inside Task 1, before the field goes.
- The rest is deletion: each task deletes code and its tests together, then runs the narrow test command.
- Wide gates run once, at the end.
- agterm-vim work happens in a native worktree on branch `remove-mosh`; agterm-agents work in
  `/Users/sasha/dev/agterm-agents/.worktrees/remove-mosh`, branch `remove-mosh`, made off `origin/main`.
- Never run `agterm`/`agtermctl` against the default socket for anything but a read; never launch or quit the app.

## Design

### Core and protocol

- `RemoteTransport` is deleted. `RemoteSession`'s attach and pane-command builders always build the ssh form;
  `moshClientCandidates`, `isPlainMoshServer`, `transportArguments`' mosh branch and the
  `InvocationError.invalidTransport` case go (the last only if nothing ssh-side throws it).
- `RemoteBinding.Origin`, the app's `RemoteRow`, and `RemoteRowBook.Record` lose `transport`.
- `ControlActions.attachRemoteSession(host:session:window:transport:)` is deleted from the protocol, the defaults,
  `HeadlessActions`, `MockControlActions` and the app. The dispatcher calls the existing
  `attachRemoteSession(host:session:window:)`.
- `ControlArgs.transport`, `moshServer`, `mosh` and their init parameters go. An old client that still sends
  `transport` has the key ignored by `Codable`.
- `SshHostPools.lease(host:transport:user:)` becomes `lease(host:user:) -> String`: nil meant only mosh. Its three
  callers lose their optional handling: the `guard let` in `ControlServer+Zmx`'s pane-command path and the optional
  chains in `AppStore+AttachedRestore` and `ControlServer+AttachedForward` (`sshHostPools?` itself stays optional).
  The "nil for a mosh row" comments in `ControlServer+HostPools` and `PaneLead` go.
- `agtermctl zmx attach` loses `--transport`, `--mosh-server`, `--mosh` and their local checks.

### Old mosh records

`RemoteRowBook` decodes the file as `[Loaded]`, a private wrapper whose `init(from:)` decodes `Record(from: decoder)`
and, from the same decoder, `try?` reads whether the old `transport` key holds a `mosh` key.
No index alignment is needed, and a hand-edited `transport` value can never fail the decode.
`load()` keeps its signature and silently omits mosh records. A new `loadReport()` returns the records and the
dropped `<host>/<remoteSessionID>` list; only the launch restore (`ControlServer+RemoteRows.restoreRemoteRows(from:)`)
uses it and logs one notice per dropped record through the app's `Logger(subsystem: "com.umputun.agterm",
category: "RemoteRowBook")`, the same category `RemoteRowBookWriter` uses:
`dropped remote row <host>/<id>: saved with the removed mosh transport`.
`load()` also runs in `RemoteRowBookWriter.init` and per window load, which therefore stay silent.
The next save writes no `transport` key, so the drop happens once.
A companion of a dropped row is itself a mosh record (a companion inherits its parent's transport), so it is
dropped too; one that survived would restore top-level through the deferred pass.

### agterm-agents

- `agterm-attach-picker`: `transport_for`, `DEFAULT_MOSH_SERVER`, `--mosh-server`, the `mosh_server` config key and
  the `ATTACH_FORM` mosh group go; `native_argv` and `headless_argv` pass no `--transport`.
  The sidecar's `transport` key is dropped: nothing in bin, rooms or hooks reads it.
- `agterm-headless-switch-rows`: `--transport` and `MOSH_HOST` go.
- `agterm-open-path`, `agterm-open-link`, `rooms/rooms-deliver.py`: the mosh regex goes from each `HOST_RES` /
  `PINNED_HOST`. The open-path HUD "Image not shown on a mosh row" becomes "… on a far row".
- `rooms/rooms_pane.py`: `MOSH_PIN`, `FAR_PIN`, `far_pin`, `_far_block`, `far_foreground`, `FAR_PROBE` and the
  `far_probe` parameter go, with any helper left unused.
- Orphan fixtures `tests/fixtures/far-sync/` (no test reads them) and the obsolete backlog item
  `docs/backlog/killed-mosh-client-may-leave-a-mosh-server-holding-a-far-session.md` are deleted.
- `codex-skills/live-review/SKILL.md` is a real copy and gets the same prose change as `skills/live-review/SKILL.md`;
  `codex-skills/ralphex-pane/launch.sh` and `codex-skills/offload-session/offload.sh` are symlinks into `skills/`.
- Kept on purpose, because they are not the removed transport: `bin/agterm-chat-pane`'s "ssh or mosh" remote-process
  guard and its test `test_chat_pane_foreign_reader.py`, the census regex in `test_remote_identity_census.py`, the
  fake `mosh` tripwires in `test_agterm_zmx_pick_headless.py` and `test_agterm_zmx_headless_new.py`, the `-mosh----x`
  name in `test_agterm_zmx_park_migrate.py`, the legacy pin in `test_agterm_mac_path_check.py`,
  `chat-reader/testdata/**/mosh-on-p4linux.jsonl` and the same room name in `chat-reader/internal/ui/screens.md`,
  the sample argv in `test_agterm_claude_map.py`, and history comments (`bin/agterm-mac-path-check`, `bin/agterm-zmx`'s
  "old mosh builder", `bin/agterm-claude-map`, `bin/agterm-zmx-park`).
  `test_bound_mosh_row_exits_1` (`test_agterm_row_origin.py`) and the mosh-named test in `test_review_live_rebased.py`
  are renamed to "far row".

## Implementation steps

### Task 1: Remove the transport from core, protocol and CLI, dropping saved mosh records (TDD)

**Files:**
- Modify: the 11 agtermCore sources listed in [Context](#context)
- Modify: `ControlDispatcherZmxTests`, `MockControlActions`, `RemotePresentationStateTests`, `RemoteRowBookTests`,
  `RemoteSessionTests`, `SshHostPoolsTests`, `WindowLibraryTransferTests`, `ZmxCommandsTests`, `OverlayRedirectSshTests`

- [x] write failing `RemoteRowBookTests` first: a hand-written `remote-rows.json` with one ssh record
  (`"transport":{"ssh":{}}`), one mosh record (`"transport":{"mosh":{"server":"/opt/homebrew/bin/mosh-server"}}`)
  and one with no `transport` key: `load()` returns the ssh and no-key records, and `loadReport()` names the mosh one
- [x] delete `RemoteTransport` and the mosh argv, candidates and path validation from `RemoteSession.swift`
- [x] remove `transport` from `RemoteBinding.Origin` and `RemoteRowBook.Record`, add the `Loaded` wrapper and
  `loadReport()`; remove the transport from the
  `ControlActions` overload and its default and headless implementations, `ControlArgs`, `SshHostPools.lease`,
  `AppStore+AttachedRestore`, the dispatcher and `ZmxCommands`
- [x] delete the mosh and transport tests (`RemoteSessionTests` mosh block and transport parsing,
  `ControlDispatcherZmxTests` transport and mosh refusals, `ZmxCommandsTests` transport flags, `SshHostPoolsTests.aMoshRowGetsNoPath`);
  drop the `RemoteTransport` arguments from parameterised tests, keeping their ssh case; convert every other test that
  builds a mosh origin (`RemoteRowBookTests`, `RemotePresentationStateTests`) to ssh, and delete
  `loadValidatesBothMoshPathsAfterCodableDecode` with the mosh branch of `Record.isValid`
- [x] add a `ZmxCommandsTests` case: `zmx attach H S --transport ssh` is an unknown option
- [x] `cd agtermCore && swift test` passes
- [x] commit on `remove-mosh` (revert `agtermCore/Package.resolved` first if a build touched it)

### Task 2: Remove the transport from the app

**Files:**
- Modify: `agterm/Control/ControlServer+Zmx.swift`, `ControlServer+AttachedForward.swift`, `ControlServer+HostPools.swift`,
  `ControlServer+RemoteRows.swift`, `agterm/Ghostty/PaneLead.swift`
- Modify: `agtermTests/ControlServerHostPoolTests.swift`, `ControlServerZmxTests.swift`, `RemoteRowRestoreTests.swift`,
  `CustomCommandRunnerTests.swift`

- [x] remove the transport overload and the `transport:` parameter from `ControlServer+Zmx`'s attach path, `RemoteRow`
  and every `lease` call; the HostPools guard keeps only its catalog and origin checks
- [x] `restoreRemoteRows(from:)` uses `loadReport()` and logs each dropped record
- [x] delete `testAMoshRowAndALocalRowHaveNoPool`'s mosh half, `testAMoshRowIsInsertedWithNoControlPath`,
  `testAttachCarriesTheRequestedTransportIntoThePaneCommand`, `testAMoshRecordRestoresAMoshRow`
- [x] add a `RemoteRowRestoreTests` case: a book file holding a mosh record restores only its ssh rows
- [x] build, and run the touched hosted classes with `-only-testing`
- [x] commit

### Task 3: Update agterm-vim docs and the cookbook

**Files:**
- Modify: `.claude/rules/control-api.md`, `.claude/rules/overlay-redirect.md`, `.claude/rules/rebased-overlay.md`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`, `site/commands.html`
- Modify: `FORK-NOTES.md`, `CHANGELOG-fork.md`, `cookbook/remote-session-picker/attach-remote.sh`
- Modify: `docs/backlog/two-owners-restore-attached-remote-rows.md`, `zmx-list-reports-the-socket-directory-twice.md`
- Delete: `docs/backlog/a-mosh-pane-reattaches-over-ssh.md`
- ➕ Delete: `docs/backlog/upstream-remote-attach-overlaps-the-mirror-job.md` (the mirror job it is about no longer exists)
- ➕ Modify: `.claude/rules/headless-origin.md` (`--beside` named the row's transport)

- [x] remove the transport sections and the mosh lease exception from `control-api.md`, `reference.md`, `commands.html`
- [x] reword "a plain shell or a mosh session" and the other current-behaviour mentions
- [x] `FORK-NOTES.md`: rewrite the bullet that pairs `--transport` with `session split --command`, keeping the split
  half; reword the history line "the old mosh rows were moved in" to "the old pinned rows"
- [x] `CHANGELOG-fork.md`: an Unreleased entry naming the removed flags and the dropped saved records
- [x] restore the recipe with `git show 38ea3fd7^:cookbook/remote-session-picker/attach-remote.sh` (38ea3fd7 added the mosh line)
- [x] `git grep -il mosh` lists only `docs/plans/**`, `CHANGELOG-fork.md`, `RemoteRowBook.swift`, `RemoteRowBookTests.swift`,
  `agterm/Control/ControlServer+RemoteRows.swift` (the log line), `RemoteRowRestoreTests.swift` and
  `.claude/rules/control-api.md` (the book's drop contract)
- [x] commit (the fork-docs rule asks for the docs in the commit that lands the feature: squash Tasks 1–3 into one
  commit before the merge)

### Task 4: Update agterm-agents

**Files:**
- Modify: `bin/agterm-attach-picker`, `bin/agterm-headless-switch-rows`, `bin/agterm-open-path`, `bin/agterm-open-link`,
  `rooms/rooms-deliver.py`, `rooms/rooms_pane.py`, and the prose-only files that describe current behaviour
- Modify: `tests/test_agterm_attach_picker.py`, `test_agterm_headless_switch_rows.py`, `test_agterm_open_path.py`,
  `test_agterm_open_link.py`, `test_rooms_pane.py`, `tests/fixtures/attach-picker/*.json`
- Modify: `skills/live-review/SKILL.md`, `skills/ralphex-pane/SKILL.md`, `skills/ralphex-pane/launch.sh`,
  `skills/offload-session/offload.sh`, `codex-skills/live-review/SKILL.md` (the other two codex copies are symlinks),
  `README.md`, `docs/claude/remote-agents.md`, `chat-reader.md`, `flexible-assembly-hub.md`, `docs/webctl.md`,
  `docs/headless-migration.md`
- Modify: `systemd/agterm-headless-park-shutdown.service`, `systemd/agterm-zmx-park-shutdown.service` ("over mosh" → "over ssh"),
  `tests/test_ralphex_pane_launch.py` (the comment copied from `launch.sh`)
- Modify (rename only): `tests/test_agterm_row_origin.py`, `tests/test_review_live_rebased.py`
- Delete: `tests/fixtures/far-sync/`, `docs/backlog/killed-mosh-client-may-leave-a-mosh-server-holding-a-far-session.md`

- [x] producers: remove `--transport`, `--mosh-server`, `transport_for`, the config key and the sidecar key
- [x] parsers: remove the mosh regexes and the `rooms_pane` far guard
- [x] tests: convert mosh pins to `/usr/bin/ssh -tt "p4linux"`, drop the mosh-only tests, update expected argv and HUD text
- [x] prose: rewrite current-behaviour mentions in bin, hooks, mods and the `live-review`, `ralphex-pane`,
  `offload-session` skills; leave history comments
- [x] `python3 -m pytest tests -q` passes in the worktree (red base accepted by Sasha, 2026-11-23)
  ⚠️ red on the base already, and the branch adds no failure. Mac (`uvx --with pyyaml --with pytest-xdist pytest tests -n 8`):
  7532 passed, 72 failed; the same 65 fail one at a time on the base `561c17d8`, the other 7 pass one at a time.
  p4linux (fresh clone, `TMPDIR` in `/var/tmp` because `/tmp` is near its inode limit): 7585 passed, 10 failed; the same 8
  fail on the base, the other 2 pass one at a time
- [x] `git grep -il mosh -- ':!docs/plans' ':!docs/backlog'` lists only the kept-on-purpose files named in
  [Design](#agterm-agents)
  ➕ also kept as history: `docs/claude/remote-agents.md` (the removal note and its past), `docs/claude/chat-reader.md`,
  `docs/headless-migration.md`'s dated inventory table, and `docs/webctl.md`'s Blink `mosh p4linux` (a login, not agterm)
- [x] commit on `remove-mosh`

### Task 5: Gates and commits

- [x] agterm-vim worktree root: `cd agtermCore && swift test`, `make lint`, `make test-app` (a log with
  "Restarting after unexpected exit" is red), `make release`
- [x] Linux gate on p4linux, on the committed branch: `git bundle create` of `remove-mosh`, copy it with `scp`, clone it into a fresh `/tmp`
  directory there, then `swift test --no-parallel` and `swift build --product agterm-headless`
- [x] revert `agtermCore/Package.resolved` before committing
- [x] move this plan to `docs/plans/completed/` and squash the agterm-vim branch into one commit
- [x] report to Sasha and wait for his approval before merge, push and deploy

## Post-completion

- After approval: merge `remove-mosh` into `main` in both repos (fast-forward or merge commit), `git push origin HEAD:main`
  for agterm-vim, `make deploy`, `scripts/headless/install.sh` on p4linux (`HeadlessActions` changes),
  `./install.sh` and `./install.sh --host p4linux` for agterm-agents. Remove both worktrees.
- ⚠️ Each Mac needs the agterm deploy and the agterm-agents install together. An old picker against a new
  `agtermctl` fails with `unknown option '--transport'`. p4air gets both when it is next online.
- A row the laptop attached over mosh is dropped from its sidebar on the first launch of the new build; re-attach it
  from the picker.
- ⚠️ Until that relaunch, a still-running mosh row on the laptop reads as local to the new scripts (open-path,
  open-link, room delivery). Restart agterm on the laptop when installing, or re-attach those rows first.
