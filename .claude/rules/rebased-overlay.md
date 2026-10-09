---
paths:
  - "agterm/Rebased/**"
  - "agterm/Resources/rebased/**"
  - "agtermCore/Sources/agtermCore/Rebased*.swift"
  - "agtermCore/Sources/agtermCore/ControlDispatcher+RebasedMirrors.swift"
  - "agtermCore/Sources/agtermctlKit/RebasedCommands.swift"
  - "agterm/Control/ControlServer+RebasedMirrors.swift"
  - "agtermCore/Sources/agtermCore/Session+HtmlOverlay.swift"
  - "agterm/Views/SessionSwitcher.swift"
  - "agterm/Views/PaneShortcuts.swift"
  - "agterm/Views/UndoCloseShortcut.swift"
  - "agterm/agterm.entitlements"
  - "agterm/agterm-debug.entitlements"
---

## Rebased in an overlay (fork only)

`session overlay open --rebased` shows Rebased or IntelliJ IDEA in the session's overlay slot, or one split
pane with `--pane left|right`, for the repository holding the session's working directory.
The live-review spec, plan and verification record are
`docs/plans/20261008-ide-live-review-{spec,plan,verification}.md`.
The IDE runs inside agterm's own process.
A window of another process can never be a child window, so two-process docking floats over every app or
drops behind agterm; that route was measured failing and is not to be re-proposed.
The spec, plan and live record are `docs/plans/20261007-rebased-overlay-{spec,plan,verification}.md`.

### Slots, hide and focus

- One session holds at most one Rebased overlay: `Session.rebasedOverlay` or `PaneOverlay.rebased`.
  `rebasedPlacement` derives its current slot; `updateRebasedOverlay` writes by id after swap or promotion.
  Pane holders have no terminal surface: `paneOverlayIsProgram` excludes them.
- `hidden` keeps the holder, view and callback while coverage, zoom and dashboard predicates expose
  the terminal.
  Both deck branches render held Rebased slots, including hidden ones; they never create an overlay
  terminal for them.
  A hidden panel has no chrome, backdrop, text or hit testing.
- `rebased_toggle`, the palette and `session rebased toggle` share `AppActions.toggleRebasedOverlay`.
  A held overlay hides or shows, a failed one closes so the next press retries; without one the action opens it.
  The outcome is `hidden`, `shown`, `opened`, `closed` or `refused`; UI callers beep on refusal.
- Pane visibility requires the deck visible, no session-wide cover or scratch, no `rebasedCovered`,
  and no ask over that pane.
  A session-wide ask hides either slot; an ask on the sibling pane leaves a pane IDE shown.
  A HUD leaves the pane IDE shown.
- `RebasedHost.focus(overlay:)` makes a shown pane IDE key when that pane is focused.
  An open or explicit toggle-show marks the holder for one focus attempt at its first visible show,
  through `isFocusedPane`.
  The mark clears even when focus moved away; visibility reports alone never arm another attempt.
- ⌘W over a pane IDE, a hidden pane IDE or a hidden session-wide IDE confirms before closing the session.
  A shown session-wide IDE confirms before closing only the overlay, leaving the session open.
  Both dialogs name the review and ignore `confirmCloseSession`; Cancel preserves the holder.
  `closeConfirmer` is the hosted-test seam; XCUITest's explicit bypass still applies.
  While an IDE window is key, its own ⌘W goes to the IDE.

### The JVM

- `RebasedProduct` (core) decodes `product-info.json` before the vmoptions file is read.
  Its macOS launch entry names that file relative to `Contents/MacOS`.
  `dataDirectoryName` must be a single non-empty path component, other than `.` or `..`.
- A product named exactly `Rebased` keeps `<stateDir>/rebased/{config,system,plugins,log}`.
  Other products use `<stateDir>/rebased/ide/<dataDirectoryName>/`, so a versioned name gets a fresh root.
  Lock and mirrors stay under `rebased/`.
- `RebasedInstall` builds options in order: bundle vmoptions, launch entry's `additionalJvmArguments`,
  the product root's optional `config/idea.vmoptions`, then host-owned options.
  The last group owns error/heap-dump paths, class path, the four `idea.*.path` properties,
  native-launcher properties and both screen-menu flags; user tuning cannot redirect isolated state.
  Repeated options are preserved, including `--add-opens`.
- Six IDE-root consumers: `RebasedInstall`, `JNIRebasedRuntime.prepare`, `RebasedPluginBuilder`,
  `RebasedMirrorCleanup` (legacy Rebased `system` only), `RebasedSeed`, and the agterm vmoptions read in `prepare`.
- `JNIRebasedRuntime` `dlopen`s the bundle's JBR `libjvm`, creates the JVM on an 8 MB thread and runs
  IntelliJ's main class. JBR finds an `NSApplication` already running and takes its embedded path.
  `RebasedInstall` pins `-DjbScreenMenuBar.enabled=false -Dapple.laf.useScreenMenuBar=false` (see Keys and menu).
- The JVM is never destroyed: `DestroyJavaVM` cannot be undone, and the JVM lives until agterm exits.
- Release ships `allow-jit` and `disable-library-validation` for the differently signed `libjvm`; `ci.md`
  owns the entitlement pin.

### First IDEA start

- `RebasedSeed` runs before the plugin build, under `RebasedStateLock`, only for names starting with
  `IntelliJ IDEA` and only while the product root is absent.
  Source: `~/Library/Application Support/JetBrains/<dataDirectoryName>/`.
- Config allowlist: `options`, `keymaps`, `codestyles`, `templates`, `inspection`, `ssl`, `idea.key`,
  `early-access-registry.txt`, `tbe`.
  Plugin allowlist: `IdeaVIM`, `tbe-intellij-plugin`, `claude-remarks`.
  Symbolic links, at the top or inside a copied directory, are dropped from the copy.
  `c.kdbx` and `c.pwd` are excluded; licence and IDE Services files are copied without reading or logging their contents.
- The seed writes `config/idea.vmoptions`: standalone `idea.vmoptions` when present, followed by
  `-Xms128m`, `-Xmx1g`, `-XX:ReservedCodeCacheSize=240m`, and `idea.load.plugins.id` allowing
  `com.intellij.java`, `org.jetbrains.idea.maven`, `Git4Idea`, `IdeaVIM`, `org.jetbrains.toolbox-enterprise-client`,
  `agterm.rebased.bridge`, `dev.sasha.clauderemarks`, `org.intellij.plugins.markdown`.
  A missing source writes only this vmoptions file.
  Existing roots and edited options are left alone; deleting the root repeats the seed.
- The whole root is staged in `rebased/ide/.<dataDirectoryName>-seed-<uuid>` and renamed into place.
  Leftover staging entries for that product are removed before a new seed.
  A failed copy removes staging and throws from `prepare`, leaving the next start able to retry.

### The bridge plugin

- `agterm/Resources/rebased/` is compiled at first start with the bundle's own `javac` (JBR ships no `jar`
  tool, so `/usr/bin/zip -r -X` packs it) into the product root's `plugins/agterm-bridge`, keyed by build
  number and source digest.
- The plugin publishes a `BiFunction` under the system property `agterm.rebased.bridge`. The host calls it
  for `open`, `hide`, `show`, `diff`, `openFile`, `port` and `saveAll`, and registers the native
  `hostEvent` on its class, then calls `hello`; the plugin queues events until then.
  JNI keeps a checked strong global reference from its first successful lookup, published under `state_lock`,
  for the JVM lifetime, including event-registration retries.
  `hello` removes the system property before flushing queued events, so IDEA sees only string properties.
  JNI never holds `state_lock` while calling `hello`.
- `diff <request>\t<base>\t<head>\t<0|1 merge base>\t<0|1 working tree>\t<session|pane>\t<dir>`
  runs git on a pooled thread.
  `GitChangeUtils.getDiffWithWorkingDir` supplies tracked working-copy changes; merge-base ranges
  resolve the base first.
  Session holders use `VcsDiffUtil.showChangesDialog`; pane holders use a `ChainDiffVirtualFile` editor tab.
  Empty results open nothing and report `viewOpened` with detail `0`.
  Git failures report `viewFailed`; only session holders also show an error dialog.
  `RangeDiff` keeps Git plugin classes out of Bridge's startup; the plugin compiles against
  `plugins/vcs-git/lib`.
- `openFile <request>\t<line>\t<path>\t<dir>` opens an editor on the EDT; line is 1-based, or 0 for none.
  File paths reject tabs and newlines; the directory is always the final field in either view verb.
- `port` returns the built-in server port only after its server exists; `getPort()` alone can return
  a default before startup.
- Events: `ready`, `frameOpened <dir>\t<n>`, `frameClosed <dir>`,
  `windowOpened <n>\t<welcome|dialog|popup>\t<ownerDir>`, `failed`,
  `viewOpened <request>\t<detail>` and `viewFailed <request>\t<reason>`.
  The C callback copies its strings before hopping to the main queue.
- The plugin vetoes IntelliJ's exit through `ApplicationManager.addApplicationListener` (a topic listener
  is not consulted), turns off "reopen last project", and reports a project that is already open on `open`.
- Model changes run write-safe: `invokeLater(any)` then `invokeLater(current)`. `ModalityState.any()` alone
  raises "IDE Internal Errors".
- `saveAll` answers `ok` only once the on-disk bytes equal the document's, line separator, charset and BOM
  included; after 2 s it answers a timeout instead, and quit goes on either way.

### The host and the frame

- `RebasedHost` holds the JVM state (`notStarted|starting|running|failed`) and each overlay's state.
  Each open gets its own 30 s deadline, armed after the plugin build and before `launch`, which can block
  without bound. A late `ready` serves the next open.
  A pre-frame dialog ("Trust project?") stops that overlay's deadline; its close starts a fresh 30 s.
- One project frame is shown in one place. A second session on the same repository takes it; closing that
  session or hiding its slot hands it to the newest other holder whose slot is on screen.
- Visibility and screen rectangles are keyed by overlay id.
  Each mounted slot has a reporter token; any visible reporter keeps the frame shown during a swap
  or promotion.
  The keeper asks for the current holder's rectangle, including when two holders share one host window.
- A slot counts as hidden until its view reports it visible. The palette, dashboard, pick and zoom hide the
  frame through `rebasedCovered`, and a pending `session ask` through `RebasedSlot.isVisible`: all are drawn
  inside the agterm window, under the child frame.
- A dialog attaches to the window of its owning project. One that arrives while its overlay is hidden waits,
  queued per overlay. A queued dialog is never dropped, because a modal one blocks the whole IDE: it comes up
  when its slot is visible again, or over the session's window as soon as its overlay closes. A pre-frame dialog ("Trust project?")
  belongs to the overlay being opened, on screen or queued, never to another visible project.
- The born observer sets alpha 0 on every new frame-like AWT window; `windowOpened` sets it back for anything
  that is not a project frame. The bridge reports only an `IdeFrameImpl` as a project frame, polling for
  its project however slow it is, so a project frame never arrives as a popup.
- `RebasedStateLock` holds `<stateDir>/rebased/.agterm.lock` from the first start: a second agterm on the same
  state directory is refused, because IntelliJ's own directory lock would `System.exit` it.
- `RebasedFrameKeeper` makes the frame a child window of the agterm window, so it moves with it.
  The frame is borderless: square corners, no shadow, not movable, no edge to drag. AWT rebuilds the style
  mask whenever the IDE changes a style bit, so the keeper observes `styleMask` and flattens again.
  It snaps back any size, place, minimize or full screen the IDE asks for, and keeps a new frame at alpha 0
  until 150 ms pass with no change, so a project never shows its restored bounds.
- View requests carry a fresh id and a `queued|sent|opened|failed` ledger on the model.
  Hidden requests stay queued without a deadline; visible requests arm a separate 60 s deadline when sent.
  Events update only the current request; view failure never changes the JVM state.
  An event after the deadline is dropped; the request stays `failed`.
- After `frameOpened`, port lookup runs off-main at 0.5 s, doubling to 4 s, for at most 30 s.
  A later frame starts another lookup when no port is known.
- Quit runs `saveBeforeQuit` on a worker; the main thread waits at most 2 s.
  `releaseAllBeforeQuit` then drains every holder, including failed and starting ones, without JNI
  or window hand-back.

### Keys and menu

- SwiftUI rewrites whatever `NSApp.mainMenu` is installed on every state change, so swapping in the IDE's
  menu fails. The IDE runs with its main menu in its toolbar instead.
- While an IDE window is key, `RebasedHost.monitor` sends every key to it and consumes it.
  `RebasedMenuPolicy` keeps ⌘Q, ⌘H and the toggle chord for agterm.
  `SessionSwitcher`, `PaneShortcuts` and `UndoCloseShortcut` return early on `isIDEKeyWindow`, so ⌃Tab,
  ⌃1/⌃2 and ⌘Z reach the IDE.
- Over the IDE only the direct `rebased_toggle` chord works (`RebasedKeyMatcher`), never a leader:
  ⌃Space is IntelliJ's completion.

### Control surface

- `session overlay open --rebased [--pane left|right] [--cwd DIR] [--project DIR]`
  accepts `--diff RANGE [--working-tree]` or `--file PATH[:LINE]`, plus `--on-close COMMAND`.
  `--size-percent` is session-wide only; Rebased flags require `--rebased`.
- `RebasedDiff` parses `A..B`, `A...B` or `A` for `A..HEAD`; an empty side means `HEAD`.
  Revisions starting with `-` or `.` are refused.
  `--working-tree` needs an omitted two-dot head or a merge-base range, so no explicit head is ignored.
- `--project` opens exactly that folder without walking to `.git`; beside it `--cwd` only sets callback cwd.
  CLI-relative file and project paths resolve against the caller's directory, preserving the file's
  positive line suffix.
- `session rebased show (--diff RANGE [--working-tree] | --file PATH[:LINE])` updates the held overlay.
  A hidden holder stays hidden and queues the view; no holder answers `no Rebased overlay in this session`.
- `session rebased toggle` is the chord's control twin; it returns `text` `hidden`, `shown`, `opened` or `closed`.
- Open and show return `{id, overlay, request?}`; the request identifies this view, not proof it opened.
  Same-project opens without `--on-close` reuse the holder when `--pane` is omitted or matches it.
  `session overlay close --overlay ID` closes only that holder, in either slot; it excludes `--pane`.
- Read-back while held:
  `rebasedOverlay: {project, state, error?, diff?, source?, pane?, hidden, view?, onClose?}`.
  `view` is `{request, kind, target, state, detail?}`; kind is `diff`, `working-tree` or `file`.
  `diff` is the last range asked for; `view.state: opened` confirms installation, with a file count
  or path in `detail`.
  `onClose: true` means armed; the top-level `rebased: {jvm, error?, projects, port?}` appears after
  JVM startup.

### On close

- `--on-close` requires a fresh holder and refuses before reuse or refresh can change an existing one.
  Capture command, cwd and the Mac-built environment at open, then copy the value into `Entry.onClose`.
  Without `--cwd`, capture the session's local directory or home when that path is missing or is not
  a directory.
  `CustomCommandRunner.environment(for:in:)` supplies session context without a selection, the
  control socket and widened PATH.
- `RebasedOverlayReleases` routes close, pane destruction, session/window/workspace teardown and
  frame close to one release.
  `removeEntry` succeeds once before `RebasedOnCloseRunner` starts detached `/bin/sh -c` with null stdio.
  Spawn failures are logged; no caller waits for command completion.
- Soft close retains the callback through undo and releases at finalize.
  Hide, hand-back, swap and promotion never release; confirmed quit drains entries before later
  finalize can repeat them.
  Cancelled quit and hard kill run no termination callback.
  The app can exit before the detached command delivers its message; live-review recovery must handle that.

### Remote rows

- The IDE reads only this Mac's disk, so a remote row (`Session.remoteHost`) opens a `RebasedMirror` (core):
  a clone under `<stateDir>/rebased/mirrors/<host>/<hash>/<name>` holding the host's branches, remote-tracking branches, tags and HEAD,
  detached. Uncommitted work on the host is not in it, and edits made in the IDE never reach the host.
- `--cwd` (or the row's cwd) is the host's path. `RebasedMirrorRefresh` asks the host for its repository top
  over ssh (`git upload-pack` does not look upward), then `git fetch`es over ssh with `BatchMode`, off the
  main actor. The slot reads `fetching` with `source: host:path` until it lands, then opens on the mirror.
- Every open refreshes, so a range names the host's newest commits. One for the repository already shown
  refreshes and then sends its `--diff`; `session rebased show --diff` refreshes too.
  A failed refresh fails the view request and sends no older diff. A second open while one fetches,
  and one for another repository, are refused.
- Every job that writes under `mirrors/` runs on `RebasedHost`'s one serial mirror queue: each refresh, the
  start prune, each on-demand prune (dry run included) and each marker touch.
  So two rows on one repository never fetch into one directory at once, and a second row's open or a prune
  waits behind a running refresh, about 15 minutes at worst (a 30 s ssh query plus three 300 s git steps).
  Nothing on the main actor may wait on the queue: a prune job reads its in-use snapshot from main.
- `RebasedMirrorRefresh` writes `<hash>/mirror.json` (`RebasedMirrorMarker`) before the first git step and
  after the last, so a fetch that fails mid-way still counts as an open; an unreachable host writes neither.
  A mirror's age is the later of the marker and `.git/FETCH_HEAD`, else the `<hash>` directory's mtime.
- Showing a mirror's overlay touches its marker, at most once an hour, so a mirror in daily use is never pruned
  after its overlay closes.
- A prune never takes an age below 1 day: a refresh that ends just before a prune's snapshot has not reached
  the main actor yet, and only its fresh marker keeps it.
- In use, and never pruned: every overlay's project, the pending open included, every frame the IDE has open,
  and `openedThisRun`, every project the IDE opened in this JVM run, whose state the JVM can still write back.
- A local overlay whose project lies under `mirrors/` waits on the mirror queue before it opens, counted in use
  meanwhile; a clone a prune ahead of it removed fails the overlay. Other local opens never wait.
- A refresh holds the state lock for its run, as a real prune does, so another instance's prune never deletes a
  clone mid-fetch; while that instance holds the lock, the refresh fails.
- `RebasedHost.start` prunes after `prepare` takes the state lock and before `launch`, so no project an old IDE
  config reopens is a mirror being deleted, and before the deadlines are armed, so they never count it.
  It is skipped while any row fetches and when the age is 0; its error is logged and never fails the start.
- A mirror's IDE entries go before its clone, matched by `RebasedMirrorCleanup.javaHash` of the project path,
  only under an allowlist in Rebased's legacy `rebased/system/`: `projects`, `editor`, `compiler`, `vcs-log`, `vcs-users` and
  `frameworks/detection`. Shared directories such as `index` and `caches` are never opened.
  IDE config is left alone: editing it while the IDE runs is not safe.
  IDEA's per-product caches are outside this cleanup and may retain entries for removed mirrors.
- `agtermctl rebased mirror list` and `rebased mirror prune [--older-than DAYS] [--dry-run]` (see
  [[control-api]]). A real prune takes the state lock only for its run (`RebasedStateLock.withLockIfFree`),
  and is refused while another instance holds it; a list and a dry run never take it.
- `rebasedMirrorMaxAgeDays` (see [[settings]]) is the age the start prune and a bare prune use.
- The headless origin forwards `--rebased`, `session.rebased.show`, `session.rebased.toggle` and
  close-by-overlay-id to the presenting Mac.
  A forwarded open carrying `--on-close` is refused before any Mac command can run.
- Remote rows refuse `--working-tree`, `--file`, `--project` and `--on-close` on open, and the view
  flags on show,
  with `--<flag> works on a local row only`; commit diffs and `--pane` remain available.
- `site/commands.html` does not list it: fork-only commands stay off the upstream site, as for `zmx.new`.
- `rebasedAppPath` (see [[settings]]) names the bundle, default `/Applications/Rebased.app`.
  Settings > General > IDE app can name `/Applications/IntelliJ IDEA.app`; changes apply after restarting agterm.
  A running JVM keeps its product.

### Risks accepted

- Shared fate: an IDE crash is a terminal crash.
- Rebased RSS 400–830 MB with a project open; IDEA's Maven spike measured about 1.1–1.3 GB.
- IntelliJ asks "Trust project?" before the first open of each repository; agterm does not auto-trust.
  An overlay reopened while that dialog is still up gets an unpaused 30 s; only a new dialog pauses a deadline.
- IDEA's `idea.paths.selector` comes from the bundle, so Help ▸ Edit Custom Properties and Edit Custom VM
  Options open the standalone IDEA config directory, not the product root.
- Another instance holds the state lock while its IDE runs, and for the length of its prune or refresh; an IDE
  start or a refresh in that time fails, and closing the overlay and opening it again recovers.
- An open while the host is unreachable does not freshen the mirror's marker; at worst a prune removes it and
  the next open re-clones.

- A HUD over a pane IDE sits under that child window; hiding the IDE for every status toast would
  blank the review.
- A right-pane IDE can cover the search bar opened from the left terminal; live review uses the left
  pane for the IDE.
- Key-monitor audit: the three IDE-window guards and `RebasedMenuPolicy` stay unchanged for pane holders.
  ⌃1/⌃2 inside the IDE stay IDE keys; ⌃1 from the right terminal focuses the left-pane IDE.
