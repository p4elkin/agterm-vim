---
paths:
  - "agterm/Rebased/**"
  - "agterm/Resources/rebased/**"
  - "agtermCore/Sources/agtermCore/Rebased*.swift"
  - "agtermCore/Sources/agtermCore/Session+HtmlOverlay.swift"
  - "agterm/Views/SessionSwitcher.swift"
  - "agterm/Views/PaneShortcuts.swift"
  - "agterm/Views/UndoCloseShortcut.swift"
  - "agterm/agterm.entitlements"
  - "agterm/agterm-debug.entitlements"
---

## Rebased in an overlay (fork only)

`session overlay open --rebased` shows Rebased, an IntelliJ-platform git client, in the session's overlay
slot for the repository holding the session's working directory.
The IDE runs inside agterm's own process.
A window of another process can never be a child window, so two-process docking floats over every app or
drops behind agterm; that route was measured failing and is not to be re-proposed.
The spec, plan and live record are `docs/plans/20261007-rebased-overlay-{spec,plan,verification}.md`.

### The JVM

- `RebasedInstall` (core) builds the JVM options from the bundle's `product-info.json` and
  `rebased.vmoptions`. IDE config, system, plugins and logs live under `<stateDir>/rebased/`, apart from a
  normal Rebased install.
- `JNIRebasedRuntime` `dlopen`s the bundle's JBR `libjvm`, creates the JVM on an 8 MB thread and runs
  IntelliJ's main class. JBR finds an `NSApplication` already running and takes its embedded path.
  It also adds `-DjbScreenMenuBar.enabled=false -Dapple.laf.useScreenMenuBar=false` (see Keys and menu).
- The JVM is never destroyed: `DestroyJavaVM` cannot be undone, and the JVM lives until agterm exits.
- Release ships `allow-jit` and `disable-library-validation` for the differently signed `libjvm`; `ci.md`
  owns the entitlement pin.

### The bridge plugin

- `agterm/Resources/rebased/` is compiled at first start with the bundle's own `javac` (JBR ships no `jar`
  tool, so `/usr/bin/zip -r -X` packs it) into `<stateDir>/rebased/plugins/agterm-bridge`, keyed by build
  number and source digest.
- The plugin publishes a `BiFunction` under the system property `agterm.rebased.bridge`. The host calls it
  for `open`, `hide`, `show`, `diff` and `saveAll`, and registers the native `hostEvent` on its class, then
  calls `hello`; the plugin queues events until then.
- `diff <base>\t<head>\t<0|1>\t<dir>` runs `GitChangeUtils.getDiff` (after `GitHistoryUtils.getMergeBase`
  for `1`) on a pooled thread and shows `VcsDiffUtil.showChangesDialog`, a non-modal dialog of the project
  frame; a git error shows a modal error dialog. `RangeDiff` holds the Git plugin calls so Bridge loads
  without them, and the plugin depends on `Git4Idea` and compiles against `plugins/vcs-git/lib`.
  The host sends it only while the frame is shown in the asking session, since the dialog attaches there.
- Events: `ready`, `frameOpened <dir>\t<n>`, `frameClosed <dir>`,
  `windowOpened <n>\t<welcome|dialog|popup>\t<ownerDir>`, `failed`.
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
- One project frame is shown in one place. A second session on the same repository takes it; closing that
  session or hiding its slot hands it to the newest other holder whose slot is on screen.
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
- Quit runs `saveBeforeQuit` on a worker; the main thread waits at most 2 s.

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

- `session overlay open --rebased [--diff RANGE] [--size-percent N]`, `rebased_toggle` (keyless, see
  [[keymap]]) and the "Toggle Rebased" palette row.
- `RebasedDiff` (core) parses `--diff`: `A..B`, `A...B`, or `A` for `A..HEAD`, an empty side meaning `HEAD`.
  Its sides reach git as arguments, so one starting with `-` or `.` is refused in the CLI and the dispatcher.
  A `--diff` for the repository the session already shows goes to that overlay rather than being refused.
- Read-back: the session's `rebasedOverlay: {project, state, diff?, source?}`, and a top-level
  `rebased: {jvm, projects}` that is absent until the JVM has started. `diff` is the last range asked for,
  not proof the dialog opened.

### Remote rows

- The IDE reads only this Mac's disk, so a remote row (`Session.remoteHost`) opens a `RebasedMirror` (core):
  a clone under `<stateDir>/rebased/mirrors/<host>/<hash>/<name>` holding the host's branches, tags and HEAD,
  detached. Uncommitted work on the host is not in it, and edits made in the IDE never reach the host.
- `--cwd` (or the row's cwd) is the host's path. `RebasedMirrorRefresh` asks the host for its repository top
  over ssh (`git upload-pack` does not look upward), then `git fetch`es over ssh with `BatchMode`, off the
  main actor. The slot reads `fetching` with `source: host:path` until it lands, then opens on the mirror.
- Every open refreshes, so a range names the host's newest commits. One for the repository already shown
  refreshes and then sends its `--diff`; a failed refresh under an open IDE sends nothing rather than an
  older diff. A second open while one fetches, and one for another repository, are refused.
- The headless origin forwards `--rebased` to the Mac presenting the row (`ForwardPolicy`), `--cwd` unchanged.
- `site/commands.html` does not list it: fork-only commands stay off the upstream site, as for `zmx.new`.
- `rebasedAppPath` (see [[settings]]) names the bundle, default `/Applications/Rebased.app`.

### Risks accepted

- Shared fate: an IDE crash is a terminal crash.
- RSS 400–830 MB with a project open.
- IntelliJ asks "Trust project?" before the first open of each repository; agterm does not auto-trust.
