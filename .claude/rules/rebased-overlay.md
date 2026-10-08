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
  for `open`, `hide`, `show` and `saveAll`, and registers the native `hostEvent` on its class, then calls
  `hello`; the plugin queues events until then.
- Events: `ready`, `frameOpened <dir>\t<n>`, `frameClosed <dir>`,
  `windowOpened <n>\t<welcome|dialog|popup>\t<ownerDir>`, `failed`.
  The C callback copies its strings before hopping to the main queue.
- The plugin vetoes IntelliJ's exit through `ApplicationManager.addApplicationListener` (a topic listener
  is not consulted), turns off "reopen last project", and reports a project that is already open on `open`.
- Model changes run write-safe: `invokeLater(any)` then `invokeLater(current)`. `ModalityState.any()` alone
  raises "IDE Internal Errors".
- `saveAll` returns only once the on-disk bytes equal the document's, line separator, charset and BOM
  included, within 2 s.

### The host and the frame

- `RebasedHost` holds the JVM state (`notStarted|starting|running|failed`) and each overlay's state.
  Each open gets its own 30 s deadline, armed after the plugin build and before `launch`, which can block
  without bound. A late `ready` serves the next open.
- One project frame is shown in one place. A second session on the same repository takes it; closing that
  session hands it back.
- A slot counts as hidden until its view reports it visible. The palette, dashboard, pick and zoom hide the
  frame through `rebasedCovered`.
- A dialog attaches to the window of its owning project. One that arrives while its overlay is hidden waits,
  queued per overlay, and is dropped when that overlay closes. A pre-frame dialog ("Trust project?")
  attaches to the slot being opened.
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

- `session overlay open --rebased [--size-percent N]`, `rebased_toggle` (keyless, see [[keymap]]) and the
  "Toggle Rebased" palette row.
- Read-back: the session's `rebasedOverlay: {project, state}`, and a top-level `rebased: {jvm, projects}`
  that is absent until the JVM has started.
- The headless origin refuses `--rebased` (`ForwardPolicy`), and a session on a remote origin gets
  `RebasedHost.remoteRefusal`: the IDE needs the repository on this Mac.
- `site/commands.html` does not list it: fork-only commands stay off the upstream site, as for `zmx.new`.
- `rebasedAppPath` (see [[settings]]) names the bundle, default `/Applications/Rebased.app`.

### Risks accepted

- Shared fate: an IDE crash is a terminal crash.
- RSS 400–830 MB with a project open.
- IntelliJ asks "Trust project?" before the first open of each repository; agterm does not auto-trust.
