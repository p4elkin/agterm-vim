# Plan: sleeping remote rows, and pooled ssh for all streams

<!-- plan-review: planning:plan-review 2026-11-21 findings=89 resolved -->

Spec: [`20261119-idle-remote-rows-spec.md`](20261119-idle-remote-rows-spec.md) (approved 2026-11-19).
Findings: [`20261119-idle-remote-rows-findings.md`](20261119-idle-remote-rows-findings.md).
Size: L, 14 tasks. What drives it:
- deck and other mount paths;
- both restore paths;
- the lead book and the reconnect machinery;
- a control command pair with read-back and events;
- per-host ssh pools over nine attach-line builders.

Route: a Claude plan pair (`pair start --mate claude`), base `ssh-idle-rows`.

## Contents

- [Overview](#overview)
- [Context](#context)
- [Development approach](#development-approach)
- [Technical details](#technical-details)
- [Implementation steps](#implementation-steps)
- [Post-completion](#post-completion)

## Overview

- **Part 1** (revised 2026-11-21, spec Part 1).
  - Rows that are not catalog rows lease their ssh channels from one merged `SshConnectionPool` per host,
    with 8 channels per master.
  - About 274 own connections to p4linux become about 35 masters, so a reconnect storm costs about 3 minutes
    instead of about 23, and stock sshd (`MaxSessions 10`) still works.
  - `ea70616a`'s own-connection default stays for every builder given no path.
- **Part 2.** A remote row with nothing local in it, off screen for `remoteSleepAfterMinutes`
  (default 30), sleeps:
  - its pane surfaces are released as a transfer releases them, which ends `login`, `sh` and `ssh -tt`;
  - the row, its presentation stream and its `remoteState` stay;
  - its panes leave the lead book, so it does not lead;
  - showing it (selection, zoom, dashboard) or a command that needs its pty wakes it with fresh attach
    lines;
  - `session text` reads the origin's screen and does not wake it.
  - At launch, restored remote rows start asleep.

## Context

- **Base.** This plan starts from fork `main` **after** the upstream merge that the `upstream-merge-2`
  session is finishing (handoff `/Users/sasha/.claude/plans/agterm-vim-upstream-merge-handoff.md`).
  - Task 1 rebases and re-checks every name below. The names come from fork `main` `4cd6654d`.
  - Task 1 (done 2026-11-20) rebased onto `97d49aa7`. Every name below exists there. The merge brought
    `AppStore+AttachedRestore.swift`, `ControlServer+AttachedRestore.swift`, `SshConnectionPool`, and a
    `controlPath:` parameter on every ssh builder.
  - Neither restore path sets `wasRestored` on a remote row (`attachedSession(from:)`, `insertRemoteRow`),
    so `CommandRestore.restorePlan` never holds back a woken row's attach line.
- **Sleep = the transfer release:**
  - `AppStore.releaseForTransfer` (`AppStore+Transfer.swift`) calls `prepareForTransfer()` on each
    surface. That claims the process exit and tears down, then nils the slots.
  - Sleep needs the pane part and `clearSearch()` only. A visible scratch or a program overlay blocks
    sleep through `holdsLocalState`. A hidden scratch (`scratchActive` false, with `scratchSurface`
    alive) may stay on a sleeping row: its `.scratch` deck host does not change.
- **Wake = the transfer renewal:**
  - `ControlServer.renewRemoteAttachments` (`ControlServer+Transfer.swift`) builds a fresh
    `ZmxLeadAttachment(claim: false)` per pane, writes `binding.attachPaneCommand(...)` into
    `initialCommand` / `splitInitialCommand`, and calls `ZmxLeadBook.shared.begin`.
  - A stored `initialCommand` is stale, because the lead book drops reports carrying an old nonce.
  - `PaneReattach.launch` needs the old view, which a sleeping row lacks.
- **Mount paths that call the pane factory** when a slot is empty (`TerminalView.makeNSView`):
  - the deck (`deckPane`, gated by `deckHostsSurface` in `WindowContentView+Zoom.swift`);
  - zoom (`WindowContentView+Zoom.swift`);
  - the dashboard (`DashboardView`).
  - A flip of the deck's gate remounts by itself, so no host-id bump is needed.
- **Lead book:**
  - `leadsHere` is `ZmxLeadBook.role(pane:) == .leader` and the user is present
    (`ControlServer+RemotePresentation.swift`).
  - `ZmxLeadBook.forget(pane:)` exists. `userReturned` takes the presenter role for every leading row.
- **Reconnect guards that already exist:**
  - `PaneLead.report` drops destroyed views;
  - `tickReconnects` cancels an entry whose slot is nil;
  - after `claimProcessExit`, `RemoteRowSupervisor.paneExited` is not reached.
  - The real gap is `isStillWaiting` / `settle` for a row that sleeps while its pane waits.
- **Restore:**
  - On the fork path, `restoreRemoteRows` (`ControlServer+RemoteRows.swift`) → `restoreRemoteRow`
    always passes `select: false`. Remote rows are not persisted (`AppStore+RemotePresentation.swift`),
    and `RemoteRowBook` saves no selection.
  - It is called at launch and from `library.onStoreLoaded` (`agtermApp.swift`).
  - `insertRemoteRow` (`ControlServer+Zmx.swift`) calls `ZmxLeadBook.begin` for both panes.
  - Remote rows are never paced: `LaunchSpawnPlan.make` lists only `wasRestored` sessions, and no remote
    row sets that flag. So sleep and wake have no pacer keys to drop.
- **Pattern for a session state command** (`session park`):
  - `Command.sessionPark` → `ControlDispatcher+Parked.swift` → `ControlActions.setSessionParked` →
    `ControlServer.setSessionParked` (`ControlServer+SessionActions.swift`) → `AppStore.setParked`
    (`AppStore+ParkedHiding.swift`), which emits `ControlEventKind.sessionParked`;
  - the CLI `SessionMetadataCommands.Park`;
  - `ControlSessionNode.parked`, filled in `AppStore.controlTree`;
  - `EventFormatter.human`;
  - `ForwardPolicy` refused, and `HeadlessActions` refuses it.
  - It is fork-only, so it appears in `reference.md` and `control-api.md`, not in `site/`.
- **Setting pattern:** `rebasedMirrorMaxAgeDays` / `effectiveRebasedMirrorMaxAgeDays` (`AppSettings.swift`).
  The UI goes in the "Sessions" section of `GeneralSettingsView` (`agterm/Views/SettingsView.swift`).
- **ssh** (after the merge):
  - `RemoteSession.sshArguments(host:connectTimeout:interactive:controlPath:options:)` adds
    `ControlMaster=auto ControlPath=<p> ControlPersist=60` when given a path. Without one, the pane line,
    `presentCommand`, `probeCommand` and `runJobCommand` pass `ownConnection` (`ea70616a`).
  - `SshConnectionPool` (`lease`, `leaseOnce`, `release`, `retain(_:prefix:)`, `ready`) and
    `PooledTransport` serve the catalog through `catalogPool(forSession:)` (`ControlServer+RemoteCatalog.swift`).
  - A pooled pane line waits for its master (`connectionWait`). The master takes a keepalive
    (`keepAliveCheck`). Its clients exit 255 at once when it dies (tested 2026-11-20).
- **Screen read:**
  - `readSessionText` is synchronous on the main actor (`ControlServer+SurfaceIO.swift`).
  - `waitsOnNetwork` (`ControlServer.swift`) routes per command.
  - The origin read is `RemoteSession.controlCommand(host:arguments: ["zmx","screen",daemon])` with
    `binding.daemon(forLocalPane:)`.

## Development approach

- TDD: write the test, see it fail, implement, see it pass. Every code task ends with its own tests.
- Decision logic goes in `agtermCore` (host-free, Swift 6, no AppKit or CoreGraphics). The app target is
  the side-effect adapter. Store sleep and wake are tested in agtermCore with a stub surface.
- **Per task:** run only that task's `Check:`. **The wide gates run once**, in Task 14.
- `scripts/test-app.sh` runs `scripts/setup.sh` first. With linked artifacts and matching stamps,
  that is a no-op. It is the one allowed use. Never delete, rebuild or relink artifacts in a pair worktree.
- Never run `agtermctl` mutations on the default socket, and never launch or quit the app. The live
  check is in Post-completion, with Sasha.
- Comments: one line, only for a non-obvious constraint.
- Mark items `[x]` as they land. Prefix new tasks with ➕ and blockers with ⚠️.
- **File owners, so the two agents do not collide** (each later task depends on the earlier one):
  - `AppStore.swift`: Task 2 (`sshHostPools`), then Task 5, then Task 8, then Task 10 (`controlTree`).
  - `AppStore+RemoteSleep.swift`: Task 5, then Task 8.
  - `agtermApp.swift`: Task 2, then Task 5, then Task 6 (the `onRowWake` line), then Task 8.
  - `WindowLibrary.swift`, `ControlServer+Transfer.swift`, `ControlServer+HostPools.swift`: Task 2, then Task 5.
  - `ControlServer+Zmx.swift`, `AppStore+AttachedRestore.swift`: Task 2, then Task 9.
  - `ControlServer+RemoteReconnect.swift`: Task 2, then Task 8 (the policy runs from `tickReconnects`).
  - `ControlServer+RemotePresentation.swift`: Task 2, then Task 12.
  - `ControlServer+AttachedForward.swift`, `PaneLead.swift`, `SshHostPools.swift`: Task 2.
  - `RemoteSession.swift`: Task 11.
  - `ControlServer+SurfaceIO.swift`: Task 6, then Task 11.
  - `ControlServer+SessionActions.swift`: Task 6, then Task 8 (`setSurfaceZoom`), then Task 10.
  - `AppActions.swift`, `AppActions+Focus.swift`: Task 6, then Task 8.
  - `ControlServer.swift`: Task 8 (`setDashboard`), then Task 10 (the dispatcher-handled switch row), then Task 11 (`waitsOnNetwork`).
  - `AppStore+SidebarSelection.swift`: Task 8.
  - `ControlServer+RemoteRows.swift`, `AppStore+Snapshot.swift`: Task 9.
  - Task 6 writes the files of the readers it fixes into this list as its first step.
  - Task 6: `Session.swift` (`rightPaneExists`, `hasSplit` and the focus predicates), `AppStore+RemoteSleep.swift`
    (the mark in `sleepRemoteRow`), `AppStore+Panes.swift` (`swapPanes`),
    `AppStore+RemoteLayout.swift` (`applyRemoteLayout`, `addOriginSplit`, `applyOriginScratch`, `attachOriginScratch`),
    `agtermApp+RemoteLayout.swift` (`closeRemovedRemotePane`), `ControlServer+Transfer.swift` (`renewRemoteAttachments`,
    `wakeAttachLines`), `agtermApp.swift` (the `onRowWake` line), `WindowContentView+Detail.swift` (`sessionDetail`),
    `AppActions+Focus.swift` (`revealActiveBlockedPane`), `CustomCommandRunner.swift` (`run(_:session:in:)`); tests in
    `SessionTests`, `AppStoreRemoteLayoutTests`, `RemoteLayoutCloseTests`, `ControlServerSessionActionsTests`,
    `ControlServerTransferTests`, `TerminalDeckTests`, `AppActionsFocusTests`, `AppStoreRemoteSleepTests`,
    `ControlServerHostPoolTests`, `CustomCommandRunnerTests`.

## Technical details

- **ssh pools:** the rules are in Task 2. A sleeping row's pane leases go at the next tick retain.
  Its wake builds new lines through the same leases (Task 5's `renewAttachLines`).
- **Model** (`Session`, not persisted). The fields are **observed**, not `@ObservationIgnored`: the
  deck gate reads `asleep`.
  - `asleep: Bool`;
  - `asleepSince: Date?`;
  - `offScreenSince: Date?`, which is nil while on screen.
- **`holdsLocalState`** is true for: `scratchActive`, `programOverlayActive` (not raw `overlayActive`,
  which a HUD sets), `htmlOverlayActive`, `rebasedOverlayActive` or `parkedRebased`, `askPending`, a
  pane overlay, or a non-empty `remoteOverlays`.
- **Eligible for sleep:** `content == .terminal`, `remoteHost != nil`, not a catalog (server window) row,
  and not `holdsLocalState`. Catalog rows do not sleep in this round, and `session sleep` refuses them.
- **On screen:**
  - the selected row of a window that is visible, not miniaturized, and in an app that is not hidden;
  - the zoom target and the dashboard members, **whatever the window state**, because their mounts
    bypass the deck gate.
  - Every way a row comes back on screen wakes it with `shown`:
    - selection;
    - the zoom target set;
    - the dashboard member set;
    - the window's deminiaturize and open, and the app's unhide.
  - The 1 s tick is the backstop. Its on-screen edge check runs on **every** tick and wakes an asleep row
    found on screen. Only the sleep policy run is limited to once per 60 s.
- **Wake hook:** `wakeRemoteRow` lives in agtermCore, and the renewal is app side. Every store reaches it
  through a `WindowLibrary.onRowWake` closure, set beside `library.onStoreLoaded` in `agtermApp.swift`.
  That block is skipped under `isHostedUnitTest`, so hosted tests set the closure themselves.
- **Policy:** `RemoteSleepPolicy.rowsToSleep(rows:now:after:) -> [UUID]` over candidates
  (`id`, `eligible`, `asleep`, `offScreenSince`). After 0 means never. Timing is per row, so a split row
  needs no special case.
- **Clock:** `offScreenSince` is set when the row leaves the screen, and cleared while on screen. A wake
  of a row that is not on screen (`command`, `pty`) sets it to now, so the next tick does not put it
  straight back to sleep.
- **Reasons** (`RemoteSleepReason`, in agtermCore): sleep `timer` / `command` / `launch`; wake
  `shown` / `command` / `pty`.
- **Tree:** `asleep: true` and `asleepSince` (epoch seconds), both omitted while awake.
- **Events:** `session.slept` and `session.woke`, with `reason` in the payload and in `EventFormatter.human`.

## Implementation steps

### Task 1: Rebase onto the merged main and re-verify names
owner: lead

**Files:** this plan.

- [x] once `upstream-merge-2` has pushed to `origin/main`, rebase `ssh-idle-rows` onto it
- [x] re-open every construct under Context, fix moved names in this plan, and record whether `catalogPool` / `controlPath:` / `AppStore+AttachedRestore.swift` exist; on the upstream path, check whether `CommandRestore.restorePlan` holds back a restored remote row's `initialCommand` (`wasRestored`, restore-command support off), which would make a woken row open a plain shell (2026-11-20: it does not; see Context. The merge's `SshConnectionPool` and `ownConnection` replaced Task 2's design, per Sasha's choice)
- [x] check that the main checkout's stamps equal what this tree's `setup.sh` writes, so `pair start --link` may share artifacts (2026-11-20: both match)

Check: `git merge-base --is-ancestor origin/main HEAD && cd agtermCore && swift build`

### Task 2: Per-host ssh pools for attached rows
depends: 1

Spec Part 1 (revised 2026-11-21). Reuse `SshConnectionPool` unchanged. Do not touch `ownConnection` or its
`RemoteSessionTests`: a builder given no `controlPath` keeps its own connection, as `ea70616a` wants.

**Files:**
- Create: `agtermCore/Sources/agtermCore/SshHostPools.swift` (the per-host registry)
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift` and `AppStore.swift` (inject the registry: the library holds it and `makeStore` hands it to each store)
- Create: `agterm/Control/ControlServer+HostPools.swift` (`sshPool(forSession:)`, the lease retain)
- Modify: `agterm/agtermApp.swift` (build the registry and one runner in `init`; widen `PaneLead.catalogChannel`'s installer)
- Modify: `agterm/Ghostty/PaneLead.swift` (`catalogChannel`'s doc; `PaneReattach.originScratch` takes a path)
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift` (`startRemotePresentation`, `stopRemotePresentation`, `showReplicaOverlay`, and the last retain in `startRemoteTick`'s exit and `stopRemotePresentations`)
- Modify: `agterm/Control/ControlServer+RemoteReconnect.swift` (`tickReconnects`: the probe, and the call to the retain)
- Modify: `agterm/Control/ControlServer+Zmx.swift` (`insertRemoteRow`)
- Modify: `agterm/Control/ControlServer+Transfer.swift` (`renewRemoteAttachments`' two lines)
- Modify: `agterm/Control/ControlServer+AttachedForward.swift` (`paneAttach`, `scratchAttach`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+AttachedRestore.swift` (`attachLine`)
- Tests: create `agtermCore/Tests/agtermCoreTests/SshHostPoolsTests.swift` and `agtermTests/ControlServerHostPoolTests.swift`; add to `agtermCore/Tests/agtermCoreTests/AppStoreAttachedRestoreTests.swift`

**Rules:**
- **Registry.** `SshHostPools` (`@MainActor` class in agtermCore, **no shared instance**) has:
  - `init(root:owner:runner:)`;
  - `pool(for host:) -> SshConnectionPool`, which creates one pool per host on first use, keyed
    `"\(owner)|host|\(host)"`;
  - `lease(host:transport:user:) -> String?`, which returns nil for any transport but `.ssh`.
  - It never closes a pool: an idle master ends after `ControlPersist=60`.
- **Injection, as `launchPaneDrop` is injected.** `WindowLibrary` takes an optional `SshHostPools` as an
  **init parameter**, stored before `bootstrap()` because launch stores load inside `init`.
  `restoredRuntime` gets a new argument for it. `makeStore` hands it to each `AppStore` (`sshHostPools`, nil by default). Core `attachLine` calls
  `sshHostPools?.lease(...)`. A nil registry keeps today's lines, so Linux, the headless origin and every
  test that builds no registry stay unchanged. Tests that want one build their own with a fake runner,
  so no state is shared between parallel suites (`.claude/rules/tests.md`).
- **Built early, outside hosted tests.** `agtermApp.init` builds the registry only when
  `!isHostedUnitTest`, and **before** `restoredRuntime` builds the `WindowLibrary`, because
  `attachedSession(from:)` builds lines inside `loadStore`. Its arguments:
  - `root` = `ControlServer.sshPoolRoot`, `owner` = the state directory path;
  - one `RemoteCommandProcessRunner()` built there and passed to the registry **and** to
    `ControlServer(remoteRunner:)`, so both use one runner. The registry takes `any RemoteCommandRunner`
    and wraps it as `SshConnectionPool.Runner` with a 15 s deadline, as `startRemoteCatalog` does;
  - `ControlServer` reads `library.sshHostPools` and stores no copy, so a test cannot give the two different registries.
- **Mosh.** A mosh row never gets a path: `RemoteSession.attachCommand` throws `invalidTransport` on
  `controlPath` with mosh.
- **`sshPool(forSession:)`** returns `catalogPool(forSession:)` for a catalog row. For any other row whose
  binding transport is `.ssh`, it returns the registry's `pool(for:)`. Otherwise it returns nil.
- **Lease users** are the catalog's names: `pane:<local pane identity>`, `pane:<scratchClientIdentity>`
  for the origin scratch, `present:<row id>`, `job:<job>`, and the probe's `leaseOnce`.
- **The nine pane-line builders that lease:**
  - `insertRemoteRow`, both panes;
  - `renewRemoteAttachments`, both panes;
  - `paneAttach` and `scratchAttach`;
  - core `attachLine`;
  - `PaneReattach.launch`, through `PaneLead.catalogChannel`. Keep the upstream name, widen its doc, and
    point its installer at `sshPool(forSession:)`;
  - `PaneReattach.originScratch`.
- **Other links that lease:** the presentation stream, the overlay job and the reconnect probe.
- **`insertRemoteRow` order.** "Nothing is inserted when a pane command cannot be built" still holds:
  - first build both lines without a path, exactly as today, as validation; a throw refuses with no model
    change;
  - then `addSession` and `setSplitVisibility`, which mint the pane identities;
  - then, for `.ssh`, lease `pane:<identity>` and rebuild both lines with the path. That rebuild cannot
    throw once the first build passed. Assign `initialCommand` / `splitInitialCommand` in the same
    main-actor turn, before the deck mounts, as the split line is assigned today.
- **Retain on the 1 s tick**, called from `tickReconnects`. For each host pool:
  - `retain(_:prefix: "pane:")` keeps:
    - the left and split panes (`hasSplit`) of every row on that host that is open in a live store or
      pending close (as `heldSession` does) and not `ended`;
    - `pane:<scratchClientIdentity>` while that row's `originScratch` is set (a built line counts before it mounts).
  - `retain(_:prefix: "present:")` keeps `present:<id>` for each `remoteClients` key.
    `stopRemotePresentation` cannot release it on a close, because the row has already left the store.
  - The set comes from rows, not from mounted surfaces, so a line that is built but not mounted keeps
    its lease.
  - Task 5 adds the `!asleep` filter for the left and split panes.
  - `startRemoteTick` (`ControlServer+RemotePresentation.swift`) stops once nothing is left to tick. Run the
    retain once more at that exit, and in `stopRemotePresentations`, so the last closed row's users go too.
    That one call site in `ControlServer+RemotePresentation.swift` is Task 2's, before Task 12.
- **Not leased, and recorded in this task:** `RemotePage`, `LinkForward`, `CatalogPage` (catalog only), and Task 11's `screenCommand`, a short call that stays on the user's ssh config.
- **Tests.** Each test builds its own registry. A hosted test of a `PaneReattach.launch` line installs `PaneLead.catalogChannel` itself, because the scene `.task` does not run under hosted tests, and restores it in tearDown.
- **Known, older than this plan:** `AttachedOriginSnapshot` saves no transport (it defaults to `.ssh`), so an upstream-restored mosh row comes back as ssh and is pooled. Record it here, and leave it alone.

- [x] write failing core tests (`SshHostPoolsTests`):
  - one pool per host;
  - nil for mosh;
  - nine leases on one host fill slot 0 with 8 and put the ninth on slot 1
- [x] write a failing core test: `attachedSession(from:)` builds lines carrying the registry's path when the store has a registry, and today's `ownConnection` line when it has none
- [x] write failing hosted tests (`ControlServerHostPoolTests`):
  - `sshPool(forSession:)` gives:
    - one pool for two rows on one host, and another for a second host;
    - the catalog pool for a catalog row;
    - nil for a mosh row and for a local row;
  - `insertRemoteRow` inserts a mosh row, and its lines carry no `ControlPath`;
  - `insertRemoteRow` refuses an unaddressable row and inserts nothing;
  - an ssh row's two pane lines and its presentation argv carry its pool's path, under `pane:<identity>` and `present:<id>`;
  - the reconnect probe of a non-catalog pane leases once and releases after the run. When `ready` is false, it fails without running ssh;
  - a renewed line, a `PaneReattach.launch` line and a `PaneReattach.originScratch` line keep their pane's slot;
  - the tick retain:
    - drops a closed row's `pane:` and `present:` users;
    - keeps a pending-close row's users, which undo reuses;
    - keeps a row's scratch user while `originScratch` is set;
    - drops an `ended` row's panes;
    - runs once more when the tick stops;
  - a store built by a `WindowLibrary` given a registry restores an upstream-path row with its line on the pool path
- [x] implement the registry, the nine builders, the three other links and the retain
- [x] record here every pane, stream and job builder still passing no `controlPath`, and why
  (2026-11-21). Every pane, stream and job builder now takes its path from `sshPool(forSession:)` or
  `SshHostPools.lease`. These still pass none:
  - every builder when there is no registry: hosted tests, Linux, the headless origin, and a
    `WindowLibrary` built without one. They keep `ownConnection`, as before;
  - every builder for a `--transport mosh` row, which has no ssh channel (`lease` returns nil);
  - `insertRemoteRow`'s first build of both lines: it is the validation, and a pooled row replaces it in
    the same turn;
  - `pageServeCommand` in `ControlServer+RemoteCompanions.swift` (page serving), and `forwardCommand` in
    `ControlServer+LinkForward.swift` and `ControlServer+RemotePage.swift` (link forwards): few and short-lived;
  - short `controlCommand` / `treeCommand` calls, which stay on the user's ssh config.
  - ⚠️ `PaneReattach.originScratch` leases its own path under `pane:<scratchClientIdentity>`, as
    `PaneReattach.launch` does, instead of taking one from its caller: the caller in
    `agtermApp+PaneReattach.swift` passes the scratch daemon's identity, which the retain does not keep.
  - A row whose binding has no `origin` gets no pool: only test fixtures build one. A remote window's scratch
    reattach now rides its window's pool too, as its first attach already did.
  - A `job:` lease is released by `onReplicaOverlayClosed`. Closing the row closes its replicas first
    (`releaseLeavingSession` → `closeReplicaOverlay`), which fires it.

Check: `cd agtermCore && swift test --filter 'agtermCoreTests\.(SshHostPoolsTests|AppStoreAttachedRestoreTests|RemoteSessionTests)' && cd .. && scripts/test-app.sh -only-testing:agtermTests/ControlServerHostPoolTests`

### Task 3: Setting `remoteSleepAfterMinutes`
depends: 1

**Files:** `agtermCore/Sources/agtermCore/AppSettings.swift`, `agterm/SettingsModel.swift`,
`agterm/Views/SettingsView.swift` (`GeneralSettingsView`, Sessions), `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`

- [x] write failing tests: default 30; 0 means never; a negative value falls back to 30; a JSON round trip
- [x] add the field and `effectiveRemoteSleepAfterMinutes`, the setter, and a numeric field ("Sleep hidden remote rows after N min, 0 = never")

Check: `cd agtermCore && swift test --filter 'agtermCoreTests\.AppSettingsTests'`

### Task 4: Session sleep state, eligibility and policy
depends: 1

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Create: `agtermCore/Sources/agtermCore/RemoteSleepPolicy.swift` (policy and `RemoteSleepReason`)
- Modify: `agtermCore/Sources/agtermCore/ControlEvents.swift` (`sessionSlept`, `sessionWoke`, payload `reason`)
- Tests: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`, create `RemoteSleepPolicyTests.swift`

- [x] write failing tests:
  - `holdsLocalState` per property under Technical details, one at a time, and false for a HUD;
  - eligibility is false for a page row, a local row and a catalog row;
  - the fields are not persisted by a snapshot round trip
- [x] write failing policy tests:
  - off screen 30 min → sleeps, 29 → stays;
  - on screen → stays; not eligible → stays; already asleep → not listed;
  - setting 0 → nothing
- [x] implement the fields, `holdsLocalState`, `sleepEligible`, `RemoteSleepPolicy`, the reason enum and the two event kinds

- Done 2026-11-21: the two kinds forced an `EventFormatter.human` arm (`reason=`) here, untested; Task 10 tests it. `ControlEventProtocolTests` lists both kinds.

Check: `cd agtermCore && swift test --filter 'agtermCoreTests\.(SessionTests|RemoteSleepPolicyTests)'`

### Task 5: Store sleep and wake
depends: 2, 4

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+RemoteSleep.swift` (`sleepRemoteRow(_:reason:)`, `wakeRemoteRow(_:reason:onScreen:)`)
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (the `onRowWake` parameter)
- Modify: `agtermCore/Sources/agtermCore/WindowLibrary.swift` (`onRowWake`, passed to each store in `makeStore` as `controlEventSink` is) and `agterm/agtermApp.swift` (set it beside `onStoreLoaded`, production path)
- Modify: `agterm/Control/ControlServer+Transfer.swift` (extract `renewRemoteAttachments`' per-session body into a shared `renewAttachLines(for:)`)
- Modify: `agterm/Control/ControlServer+HostPools.swift` (the retain keeps no left or split pane of an asleep row)
- Modify: `agterm/Views/WindowContentView+Zoom.swift` (`deckHostsSurface`: no `.primary` / `.split` host while asleep; `.scratch` and `.overlay` unchanged)
- Tests: create `agtermCore/Tests/agtermCoreTests/AppStoreRemoteSleepTests.swift` (stub surfaces); `agtermTests/TerminalDeckTests.swift`

- [x] write failing core tests:
  - sleep calls `clearSearch()` and `prepareForTransfer` on both pane surfaces, nils both slots, forgets both panes in
    `ZmxLeadBook`, sets `asleep` / `asleepSince` and emits `session.slept`
    with its reason;
  - sleep is refused when the row is not eligible;
  - sleeping an asleep row emits nothing
- [x] write failing core tests: a store loaded **before** `onRowWake` is set (as the launch stores are, inside `WindowLibrary.init`) and one loaded after both reach it on wake. `makeStore` reads `self?.onRowWake` when the wake runs, as `controlEventSink` reads `onControlEvent`
- [x] write failing tests for wake:
  - wake clears `asleep`, calls the injected renewal for the row (new attach lines, `begin` for each pane) and emits `session.woke`;
  - a wake with no renewal installed leaves the row asleep and emits nothing, so a nil line never spawns a local shell;
  - `renewAttachLines(for:)` writes `RemoteSession.endedCommand(host:)` for a pane whose line cannot be built (a lost daemon), never nil
  - a wake with `onScreen: false` sets `offScreenSince` to now
- [x] write a failing hosted test: an asleep session's deck hosts neither pane, and keeps a mirrored HUD's view hosted; after wake both panes host again (the host is removed, then rebuilt, which proves `asleep` is observed) and the factory gets the renewed line
- [x] write a failing hosted test in `ControlServerHostPoolTests`: after a sleep, the next tick retain drops the row's left and split `pane:` users, and keeps `present:` and an alive hidden scratch; a wake leases them again
- [x] implement them. Transfer and wake share the renewal helper

- Done 2026-11-21. Notes:
  - The store's `onRowWake` is a getter, `() -> ((Session) -> Void)?`, so a wake can tell "no renewal" before it changes anything. Both calls return `Bool` and take `now:`.
  - ⚠️ `renewAttachLines` skips local and page rows. On a transfer, a pane whose line cannot be built now gets the ended line instead of keeping its stale one.
  - Sleep and wake emit no `tree.changed`; Task 10 adds it with the tree fields.
  - The deck test mounts `WindowContentView.detailPane` with nothing selected, because a selected pane expedites its spawn past the pacer.
  - ⚠️ Deviation, from review round 1: sleep no longer releases as `releaseForTransfer` does. A sleep runs while the app may be hidden, where `ghostty_surface_free` stalls the main thread (#1005), so it calls the new `TerminalSurface.releaseForSleep()`: its default is `prepareForTransfer()` (Linux, stubs), and `GhosttySurfaceView` claims the exit, clears `onExitHeld` / `onExit`, then `retireSurface()`. The clearing drops a held exit queued before the retire, which would otherwise reach `remotePaneStopped` and forget a woken pane's lead.
  - Sleep bumps `primaryRespawns`, so a sleep and a wake with no SwiftUI update between them still remount the left pane. `sleepEligible` excludes a row whose `rowState` is `.endedOnHost`.

Check: `cd agtermCore && swift test --filter 'agtermCoreTests\.AppStoreRemoteSleepTests' && cd .. && scripts/test-app.sh -only-testing:agtermTests/TerminalDeckTests -only-testing:agtermTests/ControlServerHostPoolTests`

Review round 1 ran: `cd agtermCore && swift test --filter 'agtermCoreTests\.(AppStoreRemoteSleepTests|SessionTests)'` (142 tests, 2 suites) and `scripts/test-app.sh -only-testing:agtermTests/TerminalDeckTests -only-testing:agtermTests/ControlServerHostPoolTests -only-testing:agtermTests/ControlServerTransferTests -only-testing:agtermTests/SurfaceRetirementTests` (41 tests, 0 failures).

### Task 6: Surface readers on a sleeping row
depends: 5

**Files:** this plan (the list), and the files of the readers that break; tests next to each one's existing tests.

- [x] before any edit, write the files this task will change into the owners list under Development approach
- [x] list every `session.surface` / `splitSurface` reader (grep), and mark each `fine` or `breaks` in this task. Known to break or to need a decision:
  - `session.swap` (answers `session not realized`);
  - `setSplitVisibility`;
  - `focusActiveSession`'s retry;
  - `AppActions.searchTarget`;
  - `font.*`;
  - the origin removing the primary pane while the slot is nil (`agtermApp+RemoteLayout.swift`
    returns early, which leaves a dead daemon);
  - a transfer of a sleeping row (`renewRemoteAttachments` would `begin` leads for it).
  - `sessionDetail` picks the right pane only when `splitSurface` is set, so a hidden split with right-pane focus shows the left pane while asleep and after a wake (found in Task 5, not run).
- [x] decide per reader: wake first, or act on the model only. Write a failing test for each one that breaks
- [x] fix them. A transfer moves a sleeping row as asleep and does not begin leads. The origin's layout change on a sleeping row updates the model only

- Done 2026-11-21. The grep (`\.(surface|splitSurface)\b` over `agterm` and `agtermCore/Sources`) has 173 hits, by
  hand about: 6 fixed, 14 Task 11, 8 Task 8, 9 Task 7, 38 not `Session` slots (other types, enum cases, docs), 98 fine.
  Bare reads inside `Session.swift` were read too. The tally counts grep hits; the list below counts readers, and some
  fixes (`addOriginSplit`, `renewRemoteAttachments`, the `Session` predicates) have no hit.
  - **Breaks, fixed here (8):**
    - `AppStore.swapPanes` (`session.swap`, Swap Panes): model only. An asleep row moves as slots, as `allowingUnrealized` does.
    - `applyRemoteLayout`'s `realized` gate dropped the origin's axis and its `setSplitVisibility` call: model only.
      `setSplitVisibility` itself is fine.
    - `addOriginSplit` → `ControlServer.paneAttach` began a lead and leased `pane:` for a pane with no surface: model only.
      The binding, identity and `splitCommandWait` are set; the line stays nil for the wake.
    - `closeRemovedRemotePane` with the primary slot nil: model only. `closePrimaryPane` runs at once (promotes a mapped
      split, or closes the row), since no exit is coming.
    - `renewRemoteAttachments` on a transfer: the row moves asleep, with no leads and its lines untouched.
    - `sessionDetail`, and the `Session` predicates it must agree with (`activeSurface`, `focusedPane`, so `rendersPane`,
      `focusedCwd`, the focused title): one `Session.rightPaneExists`, a split surface or a split a sleep released
      (`splitReleasedAsleep`). `sleepRemoteRow` sets it only for a split whose surface it released, or one already
      marked that no wake built again; a split surface built again, or the split going (`hasSplit` false), clears it.
      ⚠️ Scoped to slept splits on purpose. A wider rule ("the origin runs this split") broke 4 existing tests
      (`RemotePresentationStateTests`, `ControlServerRemotePresentationTests`) that hide a right-focused split with
      no surface and treat its pane as not shown. By the hidden-maximize rule that pane is the shown one, so those
      tests pin a state the user never sees; whether to widen the rule is the lead's call.
    - `revealActiveBlockedPane`'s `.right where splitSurface != nil`: moved focus off an asleep row's blocked right
      pane. Now `rightPaneExists`.
    - `CustomCommandRunner.run(_:session:in:)` (`keymap run --target`): spawned with `pane: .left` for an asleep row
      whose hidden split has focus, while `tree` and `focusedPane` said right. Now `rightPaneExists`. Review round 1.
  - **Decided, no change here:**
    - `focusActiveSession`'s retry: fine. A nil target retries 12 × 30 ms and stops; the row it reaches is the selected
      one, which Task 8 wakes, and the remounted pane's `isActive` host takes focus.
    - `AppActions.searchTarget` (⌘F): fine after Task 8, for the same reason; no wake here.
    - ⚠️ `font.*` and every other SurfaceIO arm (`paste`, `selectall`, `copy`, `type`, `cursor`, `search`; `text` reads the origin),
      plus `session.lead` (`ControlServer+PaneLead.swift`): **wake first, Task 11.** They answer `session not
      realized`, and their `--pane right` arms answer `session has no split pane` for an asleep split row. They are
      synchronous resolver closures and need Task 11's wake-and-wait helper. Deviation: the Task 6 list named `font.*`.
    - Zoom and dashboard mounts (`WindowContentView+Zoom`, `DashboardView`, `reconcileDashboardMembers`,
      `selectDashboardMember`, `TerminalZoomSurface.surface(in:)`): would build with the stale line. Task 8 wakes first.
    - ⚠️ Reconnect: `waitToReconnect`, `waitingSurface`, `remotePaneHeld`, `reattachRespawned` and the supervisor's
      `reattach` closure in `agtermApp.swift` skip a nil slot. The `settle` gap is Task 7's (`RemoteRowSupervisor.swift`).
    - `ControlServer+Zmx.swift` (Task 9's file): `liveAttributions` is local rows only and `applyKilledPaneExit` is
      reached only for local rows (`zmx.kill-pane` is forwarded for attached rows). Fine.
  - **Accessors** (`activeSurface`, `addressableSurface`, `topmostSurface`, `onScreenSurface`, `focusTarget`): their
    command-arm callers are Task 11's; their focus callers are the two decided above.
  - **Fine (nil-safe):**
    - teardown and release through optional chaining (`AppStore` close paths, `AppStore+PendingClose`,
      `WindowAccessor`, `AppStore+Companions`, `AppStore+Transfer`, `AppStore+RemoteSleep`);
    - `===` checks from a view's own callback (`agtermApp` factories, `handlePaneExit`, `handleRemotePaneHeld`,
      `NotificationManager`, `AskDialogView`);
    - local-only or catalog-only (`ZmxLifecycle`, tree attributions, `AppDelegate` exit capture,
      `CatalogProjection`, `AppStore+Catalog`, `ControlServer+RemoteCatalog`, `AppStore+Messages.livePanes`,
      which every caller reaches only for local rows, Headless and ServerKit);
    - read-backs that answer empty (tree `realized`, pane tokens, foreground, font sizes; Task 10 adds `asleep`),
      `ControlServer+Hud` metrics (fall back to the estimate), `ControlServer+Mark` (no pty, no mark),
      `SettingsModel` config push, dashboard font overrides, `PaneLeadCover`, `CustomCommandRunner`'s
      key-down and keybind readers (surface identity, `focusedPane`);
    - forwarded to the origin for attached rows by `attachedRoute`: `ControlServer+Restart`, `ControlServer+Companions`
      duplicate, `session.split` / `split close`;
    - `canCloseRemovedRemotePane`, `hasLiveSplit`, `closeRemovedRemotePane`'s split branch (already model only);
    - not `Session` slots (`.surface` of another type): `GhosttyCallbacks`, `SurfaceRetirement`, `QuickTerminal`,
      `DashboardMember`, `TerminalZoom` ids, `PaneSource.surface`, `ServerActions`.
  - ⚠️ **Task 11 and Task 12, a decision for the lead:** a woken row whose split is hidden with right focus mounts only
    the right pane, so its primary never attaches.
    - `leadsHere` reads the primary pane only, so the row takes no presenter role while on screen (Task 12).
    - `addressableSurface` (`surface ?? splitSurface`) sends a main-pane `type` / `paste` / `font` to the right pane, and
      `TerminalZoomSurface.primary.isAvailable` drops the primary from `tree`. A Task 11 wait for the left pane's first
      lead report never ends (Task 11).
    - The choice: mount both panes on wake, or have those readers treat the unmounted primary as asleep.
  - **Fixed in review round 1, not a pane-slot reader:** `applyOriginScratch` attached a scratch the origin showed on
    an asleep row (one ssh and a lead) and turned `scratchActive` on.
    - Asleep, it now records only `scratchDaemon` and `originScratchClient`. A replaced or gone scratch still closes.
    - The production `onRowWake` is `ControlServer.wakeAttachLines`: `renewAttachLines`, then
      `AppStore.attachOriginScratch`, which applies the saved layout's scratch. A transfer calls `renewAttachLines`
      alone, since `AppStore+Transfer` drops the scratch on purpose.
    - `wakeRestoredAttachedRow` needs no scratch step: the layout is not persisted, so at the end of `restore(from:)`
      a restored row has none.

Check: `scripts/test-app.sh -only-testing:agtermTests/ControlServerSessionActionsTests -only-testing:agtermTests/RemoteLayoutCloseTests` (add an `-only-testing` for every class this task adds tests to)

Ran: `cd agtermCore && swift test --filter '^agtermCoreTests\.'` and `scripts/test-app.sh -only-testing:agtermTests/ControlServerSessionActionsTests -only-testing:agtermTests/RemoteLayoutCloseTests -only-testing:agtermTests/ControlServerTransferTests -only-testing:agtermTests/TerminalDeckTests -only-testing:agtermTests/AppActionsFocusTests -only-testing:agtermTests/ControlServerAttachedForwardTests -only-testing:agtermTests/ControlServerRemoteReconnectTests -only-testing:agtermTests/ControlServerPaneLeadTests -only-testing:agtermTests/ControlServerRemotePresentationTests -only-testing:agtermTests/GhosttySurfaceViewInputTests -only-testing:agtermTests/ControlServerZmxTests -only-testing:agtermTests/RemoteRowSupervisorTests -only-testing:agtermTests/SidebarRowViewsTests`: core 6652 tests in 307 suites passed (1 known issue, `HudHelperTests`), hosted 497 tests, 0 failures.
Review round 1 ran: `cd agtermCore && swift test --filter 'agtermCoreTests\.(AppStoreRemoteSleepTests|AppStoreRemoteLayoutTests|SessionTests)'` (186 tests, 3 suites) and `scripts/test-app.sh -only-testing:agtermTests/ControlServerSessionActionsTests -only-testing:agtermTests/RemoteLayoutCloseTests -only-testing:agtermTests/ControlServerHostPoolTests -only-testing:agtermTests/CustomCommandRunnerTests -only-testing:agtermTests/AppActionsFocusTests -only-testing:agtermTests/TerminalDeckTests -only-testing:agtermTests/ControlServerTransferTests -only-testing:agtermTests/ControlServerRemotePresentationTests -only-testing:agtermTests/RemoteRowSupervisorTests -only-testing:agtermTests/ControlServerRemoteReconnectTests` (392 tests, 0 failures).
⚠️ The whole core `swift test` dies with signal 11 inside `AgtermHeadlessKitTests` on this branch, before Task 6 as well
(checked on `1985545f`'s sources); Task 14 must look at it.

### Task 7: Reconnect does not wake or reattach a sleeping row
depends: 5

**Files:** `agterm/Control/RemoteRowSupervisor.swift` (`isStillWaiting`, `settle`), `agtermTests/RemoteRowSupervisorTests.swift`,
`agtermTests/ControlServerRemoteReconnectTests.swift`

- [x] write regression tests:
  - a sleep claims the exit, so `paneExited` is not reached;
  - a reconnect entry for a slept row is cancelled by `tickReconnects`;
  - `streamFailed` on an asleep row still turns it `endedOnHost`
- [x] write a failing test: a row that sleeps while its pane waits to reconnect does not reattach at `settle`
- [x] add the guard to `isStillWaiting` / `settle` only

- Review round 1 (2026-11-21, lead's decision to edit `AppStore+RemoteSleep.swift`): `sleepRemoteRow` also cancels
  the panes' `RemoteReconnectBook` entries, drops their held exits, and resets `.disconnected` to `.attached`; an asleep
  row's `settle` keeps only `.endedOnHost`. Each has a test that fails without it.

Check: `scripts/test-app.sh -only-testing:agtermTests/RemoteRowSupervisorTests -only-testing:agtermTests/ControlServerRemoteReconnectTests`

### Task 8: On screen, the timer, and wake on show
depends: 2, 3, 5, 6

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`selectedSessionID` didSet wakes an asleep row with `shown`, except while `restoringSelection` is true: Task 9 wakes the restored selection itself)
- Create: `agterm/Control/ControlServer+RemoteSleep.swift` (per-row on-screen edges, an injected `windowOnScreen(id)` check, and a `windowBecameVisible(id)` entry that the NSWindow deminiaturize/open and NSApplication unhide observers call (registered in the same file); tests call the entry directly; on the existing 1 s remote tick, an on-screen edge check every tick and a policy run at most once per 60 s; injected clock)
- Modify: `agtermCore/Sources/agtermCore/AppStore+SidebarSelection.swift` (`preservingSelection`: on the exit where the body changed the selection, after `restoringSelection = false`, wake `activeSession` with `shown` if it is asleep)
- Modify: the dashboard member setters and the zoom paths, waking every member or target **before** it mounts: `AppActions.toggleDashboard` and `toggleTerminalZoom` (`AppActions.swift`), `ControlServer.setDashboard` (`ControlServer.swift`), `ControlServer.setSurfaceZoom` (`ControlServer+SessionActions.swift`), `reconcileDashboardMembers` (`agterm/Views/WindowContentView+Dashboard.swift`)
- Modify: `agterm/Control/ControlServer+RemoteReconnect.swift` (`tickReconnects` calls the policy run; `startRemoteTick` stays as it is)
- Modify, as needed: `agtermCore/Sources/agtermCore/AppStore+RemoteSleep.swift`, `agterm/AppActions+Focus.swift`, `agterm/agtermApp.swift` (the production `windowOnScreen` injection)
- Create: `agtermTests/ControlServerRemoteSleepTests.swift`

- [x] write failing tests:
  - selecting an asleep row wakes it (`shown`);
  - opening the dashboard wakes its asleep members before any tile mounts;
  - zooming an asleep row wakes it first;
  - a tick with a fake clock sleeps an unselected eligible row after the setting and leaves the selected, zoomed and dashboard rows;
  - a minimized window's selected row counts as off screen;
  - un-minimizing that window, and unhiding the app, wakes its selected row;
  - a zoom target and a dashboard member in a minimized window count as on screen and never sleep; (deliberate: those two mounts bypass the deck gate, so a slept member would leave a blank tile, while a minimized deck simply shows nothing)
  - a wake by command then a tick leaves the row awake;
  - an asleep selected row in a visible window, with no wake call, is woken by the next tick;
  - core, in `AppStoreRemoteSleepTests`: a `store.preservingSelection` body that removes the selected row reselects an asleep row and wakes it;
  - the 60 s limit lives in the policy run itself, so an extra `tickReconnects` call (`retryRemoteLinksNow`) does not run it sooner
- [x] ➕ (from Task 6) a wake brings back what existed before sleep: with the split hidden and focus on the right pane, the primary pane gets its surface too, not only the right one. Today only the shown pane mounts, so the primary never attaches, and `leadsHere`, `addressableSurface` and `tree` then read the wrong pane. Write a failing hosted test (wake that row; both slots hold a surface, and the primary's first lead report makes `leadsHere` true), then fix it
- [x] ➕ (from Task 5's review) a row that went `endedOnHost` while asleep wakes into `RemoteSession.endedCommand(host:)`, not a fresh attach: `renewAttachLines` writes the ended line for such a row. Write a failing hosted test first
- [x] implement the edges, the tick hook and the wake-before-mount calls

- Done 2026-11-21:
  - `AppStore.wakeShown` is the one wake for a selection, a zoom target and dashboard members; the five mount paths
    and `selectedSessionID` / `preservingSelection` call it.
  - `windowOnScreen` defaults to the production check (`ControlServer.windowIsOnScreen`), so `agtermApp` injects
    nothing. The deminiaturize and unhide observers re-check every window instead of reading the notification's
    window (a payload carried into the main actor fails Release WMO).
  - The hidden-split primary is built off the deck in `agtermApp.wakeRenewal`, which production's `onRowWake` and the
    test share; `surfaceEnv` gained a static form for it.
  - Mutation check: with the tick hook, `wakeShown` and the primary build removed, 8 of 10 tests failed; the two
    "stays awake" tests now also assert that a control row slept, so they fail too.
  - The three Task 5 findings the timer would reach are closed (Task 5 approved): `releaseForSleep` retires the
    surface without waiting, `sleepRemoteRow` bumps `primaryRespawns` so the primary host remounts, and
    `sleepEligible` excludes `.endedOnHost`. A wake of an `ended` / `endedOnHost` row writes the ended line with no
    lead, lease or origin scratch.
  - Review round 1: a window opening re-checks the windows (`.agtermWindowAttachmentChanged`, observed from
    `ControlServer.init`); tests cover the `active` zoom arm, `toggleTerminalZoom`, the dashboard reconcile, the
    wake's clock reset, and the deck building only the right pane beside the off-deck primary.
  - Also ran: all `agtermCoreTests` (6659 passed), and hosted `ControlServerSessionActionsTests`, `DashboardViewTests`,
    `AppActionsTests`, `AppActionsNavigationTests`, `TerminalDeckTests`, `ControlServerHostPoolTests`,
    `ControlServerRemoteReconnectTests` (201 tests, 0 failures).

Check: `scripts/test-app.sh -only-testing:agtermTests/ControlServerRemoteSleepTests`

### Task 9: Restored remote rows start asleep
depends: 2, 5

**Files:**
- `agterm/Control/ControlServer+RemoteRows.swift` and `agterm/Control/ControlServer+Zmx.swift` (`insertRemoteRow(..., asleep:)`);
- `agtermCore/Sources/agtermCore/AppStore+AttachedRestore.swift` (`attachedSession(from:asleep:)`) and `agtermCore/Sources/agtermCore/AppStore+Snapshot.swift` (the end of `restore(from:)`);
- tests: `agtermTests/RemoteRowRestoreTests.swift`, `agtermCore/Tests/agtermCoreTests/AppStoreAttachedRestoreTests.swift`, `agtermTests/ControlServerHostPoolTests.swift`.

**Rules:**
- **Fork path.** `insertRemoteRow(..., asleep: true)`:
  - still builds both lines first as validation, so an unaddressable record is refused, not inserted asleep;
  - then clears the line `addSession(command:)` stored, leases no `pane:` user, skips `begin`, leaves the slots empty, and sets `asleep` after its `setSplitVisibility` call.
- **Upstream path.**
  - `placingAttached` builds every attached **terminal** row asleep, with no line, no `begin` and no lease. Page rows are unchanged: they return before any line is built.
  - An asleep-built row keeps `commandWait` / `splitCommandWait` true.
  - At the end of `restore(from:)`, after `reselectIfSelectionHidden()`, core wakes the **final** `selectedSessionID` through a new internal `wakeRestoredAttachedRow(_:)` in `AppStore+AttachedRestore.swift`. It builds the lines with the private `attachLine` (or its `endedCommand` fallback), clears `asleep` / `asleepSince`, and sets `offScreenSince` nil. No app closure is needed.
  - The saved selection is the wrong value to use, because the selection can still move.
- **Events.** An upstream-path launch sleep happens while `isBootstrapping` is true, so its `session.slept` is dropped. `insertRemoteRow(asleep:)` on the fork path emits nothing either. No test expects a launch sleep event.
- **Both paths.** A row restored by both paths stays one row.

- [x] write failing tests:
  - a fork-path restore of three rows inserts all three asleep, starts three presentation streams, spawns no pane, builds no pane line, leases only `present:` users and calls no `ZmxLeadBook.begin`;
  - the same holds for the `library.onStoreLoaded` call;
  - an unaddressable fork-path record is refused, not inserted asleep;
  - regression guard (it passes today): `launchSpawnPlan().order` lists no asleep row's pane
- [x] write failing core tests on the upstream path:
  - every restored attached terminal row except the final selection comes back asleep, with no `initialCommand`, no `ZmxLeadBook` state and no `pane:` user;
  - a saved selection that is a parked local row, which `reselectIfSelectionHidden` moves to an attached row, leaves that row awake with its line;
  - a page row restores as today
- [x] keep the coverage of the existing tests that assert a restored row's line. Make the row the selected one, or check the line after a wake:
  - `RemoteRowRestoreTests`: the endpoint, the daemon, no lead claim, and the mosh server flag;
  - core `aRelaunchPutsAnAttachedRowBackInPlaceAttachingWithoutTheLead`;
  - Task 2's pool-path restore test in `ControlServerHostPoolTests`
- [x] write a failing test: waking a restored row whose daemon is gone gives `RemoteSession.endedCommand`, not a local shell
- [x] implement them

- Done 2026-11-21:
  - A selected parked row is never hidden (`isRowVisible` exempts the selection), so `reselectIfSelectionHidden`
    never moves a parked selection. The moved-selection test uses flagged sidebar mode instead.
  - Both paths share `AppStore.markRestoredAsleep` (no event). The upstream wake is `wakeRestoredAttachedRow`.
  - The restore tests' library now has a host pool, so a stream opens once the master answers; they wait for it.
  - ⚠️ For Task 14: `swift test --skip agtermCoreTests` dies mid-run with no summary (last line
    `agterm-server: could not end daemon agterm-scratch-…`), at this task's base too. `agtermCoreTests` alone passes.

Check: `cd agtermCore && swift test --filter 'agtermCoreTests\.AppStoreAttachedRestoreTests' && cd .. && scripts/test-app.sh -only-testing:agtermTests/RemoteRowRestoreTests -only-testing:agtermTests/ControlServerHostPoolTests`

### Task 10: Control API `session sleep` / `session wake`, tree, events
depends: 5, 6, 8

**Files:**
- `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher.swift`, create `ControlDispatcher+RemoteSleep.swift`
- `ControlActions.swift`, `ControlProjection.swift` (`ControlSessionNode.asleep` / `asleepSince`), `AppStore.swift` (`controlTree`), the tree human printer
- `agtermctlKit/EventCommands.swift` (`EventFormatter.human`), `agtermctlKit/SessionMetadataCommands.swift`, `SessionCommands.swift` (`Sleep`, `Wake`)
- `ForwardPolicy.swift`, `AgtermHeadlessKit/HeadlessActions.swift` (refused: "no windows or UI"), `HeadlessCatalogTests` (through `ForwardPolicy.kind(of:)`)
- `agterm/Control/ControlServer.swift` (the dispatcher-handled switch row beside `.sessionPark`)
- `agterm/Control/ControlServer+SessionActions.swift`
- Tests: create `ControlDispatcherRemoteSleepTests`; `MockControlActions`, `CommandsTests`, `EventCommandsTests`, `HeadlessCatalogTests`, `HeadlessRequests`, `AppStoreEventTests`, `AppStoreRemoteSleepTests` (tree projection); hosted `ControlServerSessionActionsTests`

- [x] write failing tests at each layer, using `session park` as the model, including:
  - the tree omits `asleep` / `asleepSince` while awake;
  - `tree` does not wake a row
- [x] refusals: not eligible (local row, page row, catalog row, holds local state); on screen
  (`shown rows stay awake`). Already in the asked state: success, no event
- [x] `wake` on a row that is not on screen uses `onScreen: false`

- Done 2026-11-21. One `ControlActions.setSessionAsleep(_:window:asleep:)` serves both commands.
  A sleep checks, in order: already asleep (ok), `Session.sleepRefusal` (`session.sleep: <reason>`), then
  `onScreenRows(inWindow:store:)` (`session.sleep: shown rows stay awake`). A wake passes that same on-screen answer as `onScreen:`.
- ⚠️ Files outside the list above:
  - `Session.swift`: `sleepRefusal` names the reason, and `sleepEligible` is now `sleepRefusal == nil`, so the two cannot drift;
  - `AgtermServerKit/ServerActions+Fork.swift` and `ServerCommandPolicyTests`: agterm-server conforms to `ControlActions` too
    and classifies every `Command`;
  - the tree human printer is `SocketClient.formatTree` (tests in `SocketClientTests`). It prints `(asleep)` in place of
    `(not realized)`, because an asleep row has no surface by design.
- ⚠️ `EventFormatter.human` already printed `reason=` (Task 5). This task adds only its test in `EventCommandsTests`.
- ⚠️ `session wake` on an awake row or a local row answers ok: it is already in the asked state. Only a failed renewal is an error.
- ⚠️ A bare `session sleep` targets `active`, which is on screen in a visible window, so it is refused. Task 13 should say so.

Check: `cd agtermCore && swift test --filter 'ControlDispatcherRemoteSleepTests|agtermctlKitTests|HeadlessCatalogTests|AppStoreEventTests|AppStoreRemoteSleepTests' && cd .. && scripts/test-app.sh -only-testing:agtermTests/ControlServerSessionActionsTests`

### Task 11: pty commands wake first; `session text` reads the origin
depends: 2, 6, 10

**Files:** `agterm/Control/ControlServer+SurfaceIO.swift`, `ControlServer.swift` (`waitsOnNetwork`, per request), `ControlServer+Restart.swift`,
`ControlServer+PaneLead.swift` (`session.lead`), the search and overlay entry points, `agtermCore/Sources/agtermCore/RemoteSession.swift` (`screenCommand`), tests in
`RemoteSessionTests` and `agtermTests/ControlServerSurfaceIOTests`

- [x] list every catalog command refused with `session not realized` and write the list into this task
- [x] ➕ (from Task 6) the readers Task 6 deferred here wake first too, each with a failing test on an asleep split row:
  `font.*`, the SurfaceIO arms (`paste`, `selectall`, `copy`, `type`, `cursor`, `search`; `text` reads the origin, as
  below) and `session.lead`.
  Their `--pane right` arms answer `session has no split pane` rather than `session not realized`, so the list above
  misses them unless they are named
- [x] write failing tests:
  - `type` to an asleep row wakes it (`pty`), waits for the pane's first lead report (not
    `isRealized`), types once, and fails with a clear timeout error after a bounded wait;
  - `text` on an asleep row runs the origin screen command off the accept thread and does not wake
- [x] run `session.text`, `session.type` and the other commands that may wake off the accept thread always (`waitsOnNetwork` sees only the command, not the target)
- [x] implement the wake-and-wait helper and `screenCommand` through `binding.daemon(forLocalPane:)`. `screenCommand` takes no pool lease: it is a short call on the user's ssh config (Task 2's list)

- ⚠️ For the lead (from Task 8): a wake of a split hidden with focus on the LEFT mounts only the left pane, so the right
  pane never attaches and a `--pane right` wait for its first lead report never ends. Task 8 builds only the hidden
  primary (the case its ➕ item names). Decide: build the hidden right pane on wake too, or fail that wait at once.
  - Done: the wake builds it (`agtermApp.wakeRenewal`, Task 8's file), when a sleep released it (`rightPaneExists`).
    A split hidden since launch has no right surface awake either, so none is built. The deck reuses the built pane.

- Done 2026-11-21. **The commands refused with `session not realized`** on an asleep row, from the grep over
  `agterm/Control` and `AppActions.swift`, plus the same state under other words:
  - wake first: `session.type`, `session.paste`, `session.selectall`, `session.copy`, `session.search`,
    `session.lead`, `font.inc`, `font.dec`, `font.reset`, and `surface.cursor` (it answers `surface not available`);
    their `--pane right` arms answer `session has no split pane`.
  - read the origin, no wake: `session.text`.
  - no wake, decided elsewhere: `session.swap` (Task 6, model only); `session.restart` (an attached row forwards it
    to the origin in `attachedRoute`); `session.companion.duplicate` (`pane is not realized`, reached only for local
    rows: a remote one is refused first).
  - not in the list: `session.overlay.open` answers no `not realized` and builds its own surface or opens on the
    origin, so it does not wake. ⚠️ The spec's example list names `overlay`.
- How it works: one pre-step in `ControlServer.dispatch`, `asleepRowResponse` (new `ControlServer+AsleepRows.swift`),
  before `ControlDispatcher`. The pane decision is host-free: `PtyWake.pane(of:on:surface:)` (new
  `agtermCore/.../PtyWake.swift`, tests in `PtyWakeTests`). It answers nil, so the arm answers in its own words, for an
  awake row, `--pane scratch` (a sleep keeps the scratch), a missing split, an unknown token, and arguments the arm
  refuses (no text, a NUL, a bad `--pane`, `search --to close`).
  - A hidden split no sleep released (hidden since launch, or a restored row) has no right surface awake either, so a
    wake command for it answers `session has no split pane` at once with no wake; `session.text` still reads it.
  - The wake: `wakeRemoteRow(.pty, onScreen:)` (the `setSessionAsleep` answer), then a poll every 50 ms until
    `ZmxLeadBook.role(pane:)` is set, any role. A follower report ends the wait too; the arm then answers
    `pane is in use on the Mac it runs on…`. The pause is the injectable `ptyWakeSleep`, the clock `hudClock`.
  - Bound: `ptyWakeTimeout` = 20 s, above a pooled line's 15 s wait for its master. Errors:
    - `<cmd>: the row was asleep and its <left|right> pane did not attach within 20 s; the command did not run`;
    - `<cmd>: the row was asleep and its <pane> pane has nothing to attach; the command did not run` at once, when no
      attach began (a row ended on its host);
    - `<cmd>: the row was asleep and could not be woken; the command did not run`.
    The wake stands after a timeout.
  - `session.text`: `RemoteSession.screenCommand`, `originScreenDeadline` 10 s, through `remoteRunner`, no lease.
    `--lines` keeps the last lines (`ZmxScreen.lastLines`), and `--all`/`--lines` ask for the scrollback. A failed
    read says `session.text: the row is asleep and its screen on <host> could not be read: <ssh stderr>`.
  - `waitsOnNetwork` now holds `session.text` and every `PtyWake.commands` entry.
- ⚠️ Deviations:
  - `screenCommand` runs the origin's own zmx (`env ZMX_DIR=… <endpoint zmx> screen <daemon> [--all]`), not
    `controlCommand(["zmx","screen",daemon])`: agterm-headless refuses `zmx.screen` ("a Mac feature",
    `HeadlessActions.readZmxScreen`, `ForwardPolicy`), and p4linux runs it. The daemon is the plan's,
    `binding.daemon(forLocalPane:)`.
  - Files: the arms in `ControlServer+SurfaceIO.swift`, `ControlServer+PaneLead.swift` and `ControlServer+Restart.swift`
    are unchanged (one doc line in SurfaceIO), and `ControlActions` keeps its synchronous arms. New files:
    `ControlServer+AsleepRows.swift`, `PtyWake.swift`, `PtyWakeTests.swift`. Also changed: `agtermApp+RemoteSleep.swift`
    and `ControlServerRemoteSleepTests` (the hidden right pane above).
  - `surface.cursor` wakes, as the ➕ line says, though it is a read: the spec says reads never wake, and the same
    `screenCommand` reply carries the cursor column. A decision for the lead.
  - Open: an origin scratch recorded while asleep (`applyOriginScratch`) has no surface until a wake, so
    `--pane scratch` answers `session has no scratch terminal` then, without a wake.
  - `session.search` wakes with `pty`, then selects the row as it always did.
  - Open: a command right after `session wake` or a selection is not held for the attach, as before this task: the
    row is awake, so the pre-step passes it on. A pane that attaches but never reports a role (an origin zmx without
    leadership) fails at 20 s. The tests report `leader`; the role a real wake attach gets is for the live check.
- Ran: `cd agtermCore && swift test --filter 'agtermCoreTests\.RemoteSessionTests' && cd .. && scripts/test-app.sh -only-testing:agtermTests/ControlServerSurfaceIOTests`
  (exit 0: core 81 tests in 1 suite passed; hosted 18 tests, 0 failures), and `swift test --filter 'agtermCoreTests\.PtyWakeTests'`
  (8 tests) and `scripts/test-app.sh -only-testing:agtermTests/ControlServerRemoteSleepTests` (19 tests, 0 failures).
  Also, for the dispatch pre-step and the worker-thread move: hosted `ControlServerSessionActionsTests`,
  `ControlServerPaneLeadTests`, `ControlServerPageServeTests`, `ControlServerLiveResetTests` (195 tests, 0 failures).
  Mutation check, before the loop test covered right panes: without the pre-step and the right-pane build, 43 assertions
  failed across both hosted classes.

Check: `cd agtermCore && swift test --filter 'agtermCoreTests\.RemoteSessionTests' && cd .. && scripts/test-app.sh -only-testing:agtermTests/ControlServerSurfaceIOTests`

### Task 12: Presenter role while asleep
depends: 2, 5

**Files:** `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`, `agtermTests/ControlServerRemotePresentationTests.swift`, and `ControlServer+RemotePresentation.swift`
(`userReturned`, `leadsHere`) if a test fails

- [x] write tests for the behavior Task 5 defines (sleep forgets the panes, so `leadsHere` is false):
  - `userReturned` takes no presenter role for an asleep row;
  - the client keeps its last mode and sends no `presenterTake`;
  - on wake, the role is taken only when the primary pane's first report makes it leader;
  - a mirror that took the role meanwhile keeps it until this Mac's pane leads
- [x] record the observed mode in the spec's presenter paragraph (it feeds `macPlacement.mode` in agterm-agents)

- Done 2026-11-21: every test passed with no code change; the spec's presenter paragraph records the mode.

Check: `cd agtermCore && swift test --filter 'agtermCoreTests\.RemotePresentationClientTests' && cd .. && scripts/test-app.sh -only-testing:agtermTests/ControlServerRemotePresentationTests`

### Task 13: Documentation
depends: 8, 9, 10, 11, 12

**Files:**
- `plugins/agterm/skills/agterm/reference.md` and `SKILL.md`: a trigger line for "a sleeping row wakes on `type`; `text` does not wake";
- `.claude/rules/control-api.md`: the fork-only catalog, and the control-native exemption (no menu item, as for `park`);
- `.claude/rules/libghostty.md`: the deck gate exception;
- `.claude/rules/fork-merge.md`: add `deckHostsSurface` to the flagged constructs;
- `FORK-NOTES.md`, `CHANGELOG-fork.md` (Unreleased);
- the spec: fix the consumer lists, because fork-only commands are not in `site/`.

- [x] write each item; keep every fact in one place and point to it from the others
- [x] recount the consumers against the corrected spec lists

- Done 2026-11-21:
  - `control-api.md` owns the contract in a new "Sleeping remote rows (fork only)" section, and the pools in
    Remote sessions, which replaces the stale `ownConnection` paragraph. The skill, `libghostty.md`, `fork-merge.md`
    and the two fork docs point to it. `settings.md` was checked and needed no change.
  - `fork-merge.md`: `WindowContentView+Zoom.swift` joins `flagged` and `WindowContentView.deckHostsSurface` joins
    `constructs`, besides the prose list.
  - Recount: tree fields 4, commands 10, events 5, setting 6 (the spec's lists). The spec missed
    `SocketClient.formatTree`, `ServerActions+Fork`, `ControlEventProtocolTests` and `SettingsModel`'s setter.
  - ⚠️ Code and spec differ, and the docs follow the code:
    - no event carries `reason: launch`: both restore paths sleep with no event, and the upstream path's wake of
      its selection emits none either;
    - `session.overlay.open` and `session.restart` do not wake (the spec's example list names both), and
      `surface.cursor` does, although it reads (Task 11);
    - neither edge emits a `tree.changed` of its own (Task 5 left it to Task 10, which did not add it).
  - The Unreleased `ownConnection` entry in `CHANGELOG-fork.md` was edited, not contradicted: its `MaxStartups`
    sentence moved, softened, into the new pooled-ssh entry.

Check: `grep -q "session sleep" plugins/agterm/skills/agterm/reference.md && grep -q "session sleep" .claude/rules/control-api.md && grep -q deckHostsSurface .claude/rules/fork-merge.md && grep -qi "sleep" FORK-NOTES.md && grep -qi "sleep" CHANGELOG-fork.md`

### Task 14: Acceptance gates
owner: lead
depends: 2, 6, 7, 8, 9, 11, 12, 13

- [x] `cd agtermCore && swift test`
- [x] `make lint`, `make release`
- [x] `make test-app`: red if "Restarting after unexpected exit" appears or the test count drops
- [x] Linux gate on p4linux in a fresh `/tmp` clone: `swift test --no-parallel`, `swift build --product agterm-headless`
- [x] `lsappinfo list | grep -A4 agterm.debug`: no leaked test hosts

Done 2026-11-21 at `14f1ba40`:
- core `swift test`: 8346 tests; one load timeout in `ServerHookInstallTests` that passes alone (recorded in `docs/ci-flakes.md`);
- `make lint` clean; `make release` built;
- `make test-app`: 2837 tests, 0 failures, no restart;
- Linux gate on p4linux (a `git archive` of HEAD in a fresh `/tmp` dir): `agterm-headless` built, 8100 tests passed;
- no leaked `agterm.debug` host.

Check: `cd agtermCore && swift test`

## Post-completion

- **Revmux** `codex-claude` on `pair/<slug>` against `ssh-idle-rows`, per the pair skill's Finish section.
  Then Sasha merges.
- **Live check with Sasha**, in an isolated Debug instance (env scrub and `/tmp` state dir per
  `CLAUDE.md`), with one throwaway p4linux session:
  - `session sleep` ends the pane chain (`ps`), and the tree says `asleep`;
  - the presentation stream stays, `text` reads the origin, and the reported mode is recorded;
  - selecting the row wakes it; measure the time to the first frame 5 times;
  - the pane and stream ssh carry `ControlPath=/tmp/agterm-ssh-<uid>/...`; `ssh -O check` on that path answers; a slept row's master closes after 60 s when it held its last lease;
  - Settings > General shows the sleep field with the "Also loads ~/.config/ghostty/config." hint on screen and no scroll
    (`SettingsUITests.assertGeneralTabFits`; Task 3 did not run that XCUITest);
  - stop the instance by pid, and close the throwaway session.
- **Deploy** with `make deploy`. It takes effect at Sasha's next agterm restart, where the restored rows
  start asleep.
- **Footprint before and after:** `footprint`, the thread count and `rowcost.sh`, before the restart and
  after an hour of use. The expected result is about 140 fewer pane chains and at least 1.1 GB less.
- **agterm-agents:** pass the reaper's `macPlacement` work the mode a sleeping row reports (Task 12).
