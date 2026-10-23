# Plan: IntelliJ IDEA in the Rebased overlay

<!-- plan-review: planning:plan-review 2026-10-09 findings=14 resolved -->

## Contents

1. [Goal](#goal)
2. [What is true today](#what-is-true-today)
3. [What the spike measured](#what-the-spike-measured)
4. [Decisions](#decisions)
5. [Out of scope](#out-of-scope)
6. [Tasks](#tasks)

## Goal

`rebasedAppPath` can name `/Applications/IntelliJ IDEA.app`, and the overlay then runs the real IDE: code
navigation, Maven import, IdeaVim, claude-remarks. Rebased keeps working exactly as today.

## What is true today

Read on `main` at `e6ebf054`.

- `RebasedInstall` (core) decodes `product-info.json`, but its initializer also takes the vmoptions contents,
  so `JNIRebasedRuntime.prepare` must pick the file before anything is decoded. It hard-codes
  `Contents/bin/rebased.vmoptions`. IDEA's launch entry names `vmOptionsFilePath: ../bin/idea.vmoptions`,
  relative to `Contents/MacOS`.
- Every IDE directory is fixed under `<stateDir>/rebased/`: `config`, `system`, `plugins`, `log`.
  The users of the IDE root: `RebasedInstall.jvmOptions`, `RebasedPluginBuilder` (`rebased/plugins`) and
  `RebasedMirrorCleanup` (`rebased/system`); `JNIRebasedRuntime.prepare` passes the state directory to them.
  `RebasedStateLock` (`rebased/.agterm.lock`) and `RebasedMirror` (`rebased/mirrors`) are not IDE-root users.
- `RebasedHost.appPath` is read only when the JVM starts. A running JVM keeps its product.
- Settings has a text field for the bundle (`settings-rebased-app-path`, `SettingsModel.setRebasedAppPath`).
- The bridge publishes a `BiFunction` as the system property `agterm.rebased.bridge` and keeps it there.
- Product metadata: Rebased is `name: Rebased`, `productCode: IC`, `dataDirectoryName: IdeaIC1.1`; IDEA is
  `name: IntelliJ IDEA`, `productCode: IU`, `dataDirectoryName: IntelliJIdea2026.2`.

## What the spike measured

Isolated Debug instance, IDEA 2026.2.3 (`262.10968.63`), 2026-10-08/09.

- IDEA starts in-process with no change other than the vmoptions file.
- ⚠️ Maven import fails with an NPE before any project opens: IDEA copies system properties as strings, and
  the bridge property is not a `String`. Fixed by removing the property on `hello`, with the JNI side keeping
  a global reference from its first lookup.
- A fresh config shows the licence dialog, the default keymap and no plugins. Copying from
  `~/Library/Application Support/JetBrains/IntelliJIdea2026.2` fixed it: `options`, `keymaps`, `codestyles`,
  `templates`, `inspection`, `ssl`, `idea.key`, `early-access-registry.txt`, `tbe`, and the plugins
  `IdeaVIM`, `tbe-intellij-plugin`, `claude-remarks`.
- The spike's vmoptions were the standalone `idea.vmoptions` without its `-Xms`/`-Xmx` lines (it carries the
  IDE Services `-Djetbrains.tbe.*`, `-Dide.no.platform.update` and `-Dide.managed.by.toolbox` lines), then
  `-Xms128m -Xmx1g -XX:ReservedCodeCacheSize=240m` and
  `-Didea.load.plugins.id=com.intellij.java,org.jetbrains.idea.maven,Git4Idea,IdeaVIM,org.jetbrains.toolbox-enterprise-client,agterm.rebased.bridge,dev.sasha.clauderemarks,org.intellij.plugins.markdown`.
  RSS with a Maven project open was about 1.1–1.3 GB.
- IdeaVim reads `~/.ideavimrc` itself; `<leader><leader>` → `GotoImplementation` works.

## Decisions

Settled with the Codex mate on 2026-10-09; the licence copy is Sasha's answer.

1. **Product from `product-info.json`.** Metadata decoding is split from option construction: a
   `RebasedProduct` value (name, `dataDirectoryName`, vmoptions path resolved against `Contents/MacOS`, launch
   entry) is decoded first, then `prepare` reads the vmoptions file it names. `dataDirectoryName` must be a
   single path component, not empty, `.` or `..`, else the install is refused.
2. **Rebased is recognised by `name == "Rebased"`**, never by `productCode` (`IC` is also IntelliJ
   Community).
3. **One IDE root per product.** Rebased keeps `<stateDir>/rebased/{config,system,plugins,log}`, so nothing
   moves for today's users. Any other product uses `<stateDir>/rebased/ide/<dataDirectoryName>/…`; the name
   carries the version, so an IDE upgrade starts a fresh root. Lock and mirrors stay where they are.
   Mirror cleanup keeps clearing only Rebased's `system`; see Out of scope.
4. **Seed once, for IntelliJ IDEA only** (`name` starts with `IntelliJ IDEA`), when its root does not exist.
   Source: `~/Library/Application Support/JetBrains/<dataDirectoryName>/`. Copied when present: `options`,
   `keymaps`, `codestyles`, `templates`, `inspection`, `ssl`, `idea.key`, `early-access-registry.txt`, `tbe`,
   and the plugins `IdeaVIM`, `tbe-intellij-plugin`, `claude-remarks`. Never copied: `c.kdbx`, `c.pwd`.
   `idea.key` and `tbe` are licence and IDE Services state; they are copied by Sasha's choice, and nothing
   reads or logs their contents. The whole root is staged at `rebased/ide/.<name>-seed-<uuid>/{config,plugins}`
   and renamed to `rebased/ide/<name>` in one step; the state lock at `rebased/` makes that safe.
   Any `.<name>-seed-*` left by a killed start is removed first, under the lock.
   A seed failure throws from `prepare`, so the IDE never starts on a half root and the next start retries.
   The seed runs before the plugin build, which then finds `plugins` in place. A missing source seeds only the
   vmoptions file. Deleting the root starts again.
5. **agterm-owned vmoptions.** The seed writes `config/idea.vmoptions`: the standalone `idea.vmoptions`
   when present, then the lean block (`-Xms128m -Xmx1g -XX:ReservedCodeCacheSize=240m` and the plugin
   allowlist), so the later `-Xmx` wins. It is written once and never overwritten. `prepare` reads it for any
   product that has it. Option order: bundle vmoptions, the launch entry's `additionalJvmArguments`, that file,
   then host-owned options last: `-XX:ErrorFile`, `-XX:HeapDumpPath`, class path, the four `idea.*.path`
   properties, the native-launcher properties and both screen-menu flags. So user tuning overrides bundle
   defaults, and no edit can point the IDE at standalone state. No deduplication: `--add-opens` repeats on
   purpose.
6. **Bridge fix.** `hello` removes the property first, before it flushes queued events. The JNI side keeps
   one strong global reference from its first successful lookup, for the JVM's lifetime, used by every bridge
   call and by event-registration retries. `NewGlobalRef` failure is checked; publication is under
   `state_lock`, which is never held while calling `hello`.
7. **Changing the setting takes effect after restarting agterm.** The Settings field says so.
   Its label becomes "IDE app". No picker.

## Out of scope

- Renaming "Rebased" in commands, settings keys or docs.
- Auto-trusting projects; IDEA asks "Trust project?" as Rebased does.
- Seeding or a plugin allowlist for products other than IntelliJ IDEA.
- Starting a second product in the same agterm run.
- Mirror cleanup clearing a pruned mirror's entries in an IDEA root's `system`: a disk leak, not a failure.

## Tasks

Order: Tasks 1 and 2 in parallel; then 3, 4, 5, 6. No file is edited by two tasks at once, and each agent builds in its own pair worktree, so the two
parallel checks never share `build/DerivedData`.

### Task 1: Product metadata, IDE root and option order

- `RebasedProduct` (core): decode `product-info.json`; resolve the vmoptions path; validate
  `dataDirectoryName`; `ideRoot(stateDirectory:)` per Decision 3.
- `RebasedInstall` builds options from the product, the bundle vmoptions text and the optional agterm
  vmoptions text, in Decision 5's order, with paths from `ideRoot`. The screen-menu flags move here from
  `prepare`.
- `JNIRebasedRuntime.prepare`: decode the product, read the vmoptions file it names, pass no agterm vmoptions
  yet.
- Tests in `RebasedInstallTests`: IDEA's vmoptions path; Rebased by name keeps the legacy root; IDEA gets
  `rebased/ide/IntelliJIdea2026.2`; an empty `dataDirectoryName`, `.`, `..` or one with `/` is refused; an agterm `-Xmx`
  follows the bundle's; host-owned options come last (update
  `optionsFollowLauncherOrderAndOverrideStandalonePaths`).

Check: `cd agtermCore && swift test --filter RebasedInstallTests` and `make build`

### Task 2: Bridge handoff

- `Bridge.java` and `RebasedJNI.c` per Decision 6.
- Extend the Java contract test in `RebasedPluginBuilderTests.testBridgeRetainsClosedProjectsAndComparesSavedFileBytes`
  (`BridgeContracts.main`): as its last step, clear the captured `pending` list, put a new `Bridge` in the
  property, assert `apply("hello", "")` answers `ok`, and assert
  `System.getProperties().get("agterm.rebased.bridge") == null` (never `getProperty`, which answers null for
  any non-`String` value). No catch inside
  `hello`. The global reference's lifetime has no automated test; Task 6 covers it live.

Check: `scripts/test-app.sh -only-testing:agtermTests/RebasedPluginBuilderTests`

### Task 3: Plugin builder into the product root

depends: 1, 2

- `RebasedPluginBuilder` builds into the product root's `plugins`; `prepare` passes the root.
- Test in `RebasedPluginBuilderTests`: with an IDEA root, the plugin lands under `rebased/ide/<name>/plugins`.

Check: `scripts/test-app.sh -only-testing:agtermTests/RebasedPluginBuilderTests`

### Task 4: The seed

depends: 3

- Core: `RebasedSeed` plans the copies and the vmoptions text for an IDEA product, and executes the plan per
  Decision 4 (stage, rename, throw on failure). Foundation only, like `RebasedMirrorCleanup`.
- `prepare` runs it before the plugin build, reads the root's `config/idea.vmoptions` and hands it to
  `RebasedInstall`.
- Tests in core `RebasedSeedTests`: allowlist; credentials never copied; missing source writes only
  vmoptions; the vmoptions body is the standalone file then the lean block; not IDEA seeds nothing; an
  existing root is left alone, an edited `idea.vmoptions` included; a failed copy leaves no root and no
  staging directory; a stale `.<name>-seed-*` is removed.

Check: `cd agtermCore && swift test --filter RebasedSeedTests` and `make build`

### Task 5: Settings label and docs

depends: 4

- Settings: label "IDE app" and a note that a change applies after restarting agterm.
- `rebased-overlay.md` (product, roots, seed, vmoptions order, bridge handoff), `settings.md`,
  `FORK-NOTES.md`, `CHANGELOG-fork.md`.
- Recount the IDE-root users: `RebasedInstall`, `prepare`, `RebasedPluginBuilder`, `RebasedMirrorCleanup`
  (Rebased root only), `RebasedSeed` writing it, and the agterm vmoptions read: six.

Check: `make build`

### Task 6: Live acceptance and gates

owner: lead
depends: 5

Only the lead or Sasha runs this task: it launches Debug instances. One fresh isolated process per product:

- IDEA, seeded, cold start: licensed with no dialog; a Maven project imports; `<leader><leader>` reaches
  `GotoImplementation`; IdeaVim and claude-remarks are loaded; RSS recorded.
- Rebased: opens a repository and shows a `--diff` as before.

GotoImplementation, plugin behaviour and RSS are manual observations, recorded in the commit message.

Check: `scripts/build.sh` and `cd agtermCore && swift test` and `make test-app` and `make lint`

## Acceptance record

2026-10-09, lead build at `895e40cc`, fresh isolated Debug instances, one process per product.

- IntelliJ IDEA 2026.2.3 (`262.10968.63`), state `/tmp/agidea`, project `/tmp/agide-jr` (jackrabbit, Maven):
  - Seed: root `rebased/ide/IntelliJIdea2026.2` with the allowlisted config, `idea.key`, `tbe`, plugins
    `IdeaVIM`, `tbe-intellij-plugin`, `claude-remarks`; no `c.kdbx`/`c.pwd`. JVM options end with `-Xmx1g`,
    `-XX:ReservedCodeCacheSize=240m` and the plugin allowlist (IDE log).
  - "Trust project?" came up; past 30 s the overlay failed (before `895e40cc`). After Trust and a reopen: `shown`.
  - Maven import finished, `unresolved: []`, no `NullPointerException` in the log.
  - Sasha observed: no licence dialog; `<leader><leader>` reaches GotoImplementation; IdeaVim and claude-remarks work.
  - RSS about 700 MB after import, before indexing finished.
- Rebased 1.1 (`262.10968.SNAPSHOT`), state `/tmp/agreb`, same project pre-trusted, `--diff HEAD~3`:
  `shown`, `diff: HEAD~3..HEAD`; legacy layout `rebased/{config,log,plugins,system}`, no `ide/`, no seed.
  Rerun at `56b5ecc5`: Sasha saw the dialog titled `HEAD~3..HEAD` listing 3 files
  (`CachingHierarchyManager.java`, `CachingHierarchyManagerTest.java`, `CHANGELOG.md`) over the Rebased log.
- Gates: `scripts/build.sh` passed; `swift test` 5048 passed; `make lint` 0; `make test-app` 1499 run, 0 failed
  (the land's run; an earlier host exit in `SessionNavRevealTests` passed alone).
