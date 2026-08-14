---
paths:
  - "agtermUITests/**/*.swift"
  - "agtermTests/**/*.swift"
---

## Application-hosted tests (`agtermTests/`)

These run inside the app, so a mistake can kill the host instead of failing an assertion.

- **Set `isReleasedWhenClosed = false` on every test-owned `NSWindow`.** The initializer defaults true;
  `close()` can over-release a window still held by `registeredWindows`/`WindowRegistry`, then crash at
  the main-queue autorelease-pool pop. xcodebuild reports `Restarting after unexpected exit, crash, or
  test timeout`, may restart and finish, and can fail only on CI or after unrelated tests alter reuse.
  `orderOut(nil)` is safe.
- ⚠️ **Never let a synchronous test method release the last reference to a class with an `isolated deinit`.**
  It aborts the host with `malloc: *** error for object …: pointer being freed was not allocated` inside
  `swift_task_deinitOnExecutorImpl`, and every test not yet run is reported as failed against whatever suite
  it belongs to, so the failure list names suites that did nothing wrong.
  The cause is a Swift runtime defect, not agterm's: XCTest wraps a synchronous test body in
  `XCTSwiftErrorObservation`, which pushes a task-local while no task is current, and the isolated-deinit
  path then frees that non-heap task-local record. Reproducible in 22 lines with no XCTest at all —
  `TaskLocal.withValue { }` around the release, outside a `Task`. An `async` test method is unaffected
  because it runs in a real task. Raising the deployment target does not help.
  `AppActions`, `SystemWakeObserver`, `SystemAccessibilityObserver` and `WorkspaceSidebar`'s coordinator
  carry such a deinit today. Keep every instance in a property the async `tearDown` clears, as the four
  suites that hit this do, rather than in a `let` inside the test body. The app itself is not exposed: it
  holds no `@TaskLocal`.
- For a dead host, inspect `xcrun xcresulttool get test-results tests --path <xcresult>`.
  `~/.local/state/ghostty/crash/*.ghosttycrash` is a sentry envelope: split its header and
  item-header/payload pairs, write the minidump attachment as `.dmp`, then run
  `lldb -b -o "bt all" -c <dmp>`. CI discards both sources, so temporarily upload the crash directory
  and `build/DerivedData/Logs/Test/*.xcresult` under `if: failure()`, then remove the step.
- **A menu fixture needs `NSMenuItem.usesUserKeyEquivalents = false` in `setUp`, restored in `tearDown`.**
  AppKit substitutes an App Shortcut from System Settings by menu-item title as soon as the item joins a
  menu, a detached one included, replacing the key equivalent and mask the test just set. Titles like
  "Paste and Match Style", "Zoom" and "Close" are real system commands, so a developer who rebound one
  fails on his machine alone while CI stays green. `defaults read -g NSUserKeyEquivalents` names the
  bindings. Suppress the substitution rather than renaming fixtures: `CloseSessionChordTests` needs the
  real "Close" to test chord ownership, and the substitution matches invented titles just as readily.
- Never stub `GhosttyApp`; its handler is the only crash record.
- `AGTERM_HOSTED_TESTS=1`, set by the `agtermTests` scheme, renders `Color.clear` and skips the scene task
  that assigns `appDelegate.library`; it stays nil. SwiftUI's `@NSApplicationDelegateAdaptor` also makes
  `NSApp.delegate as? AppDelegate` nil, so obtain the delegate another way. The local placeholder window
  exists (`NSApp.windows.count == 1`, title "Agterm"), but another-process CI launch may hit FB11763863
  and create none.

## UI tests

- `agtermUITests/` launches the real app and drives UI behavior unavailable to host-free tests.
  Run with `xcodebuild test -project agterm.xcodeproj -scheme agterm -destination 'platform=macOS'`.
- **Run a UI test from the driver session, never from a delegated subagent.** macOS gates XCUITest on an
  Authorization Services right ("XCTest is trying to Enable UI Automation"), and the granted credential is
  scoped to the process tree that answered the prompt. Measured on 2026-08-09: six green runs from the
  driver, two `Failed to initialize for UI testing: Timed out while enabling automation mode` from a
  subagent, same command and machine. That timeout is a permission state, never a code defect, and it kills
  the runner before any test body executes — so it can never distinguish one change from another.
  `sudo DevToolsSecurity -enable` does not help; the successful runs predate it.
- **`xcodebuild` piped through `grep`/`tail` reports the PIPELINE's exit status, not its own.** Check for
  the literal `** TEST SUCCEEDED **` marker or read `${PIPESTATUS[0]}`. A failing run has been reported as
  a pass this way.
- Pass a temporary `AGTERM_STATE_DIR` in the launch environment; `agtermApp.restoredStore()` honors it.
  Verify the native `Open Directory...` panel manually.
- **Use `app.launchForUITest()`, never `app.launch()`.** FB11763863 on macOS 15+/Xcode 16+, including
  Xcode 26, can leave a
  process-launched SwiftUI `WindowGroup` with a Dock icon and AX elements but no `NSWindow`, task, or
  `onAppear`; activation/order-front APIs cannot create the missing window.
  `AppDelegate.bringUITestWindowsForward` responds by reopening
  `Bundle.main.bundleURL`. `launchForUITest()` sets `AGTERM_UITEST_FORCE_SIDEBAR_VISIBLE` in the
  environment, not arguments, launches, and activates. Keep Settings non-restorable because reopen
  retriggers restoration. Diagnose with timed `NSApp.windows.count` logging; persistent zero means
  "never created". See [[reference_swiftui-windowgroup-no-window-xcuitest]].
- **`launchForUITest` also sets `AGTERM_ZMX_SKIP`, and that is not optional.** A developer's login shell can
  hand every agterm pane to a multiplexer and exit when it detaches (`zmx attach "$AGTERM_SESSION_ID-left"
  && exit` in `~/.zprofile`), so the seeded session's shell exits about 7 seconds in, `onExit` closes the
  session, and every `session-row` disappears with no key pressed. Only a test that idles longer than that
  sees it, so it reads as a defect in whatever the test did last rather than as a dead shell. The flag rides
  the app's own environment because the pane's shell inherits it from there.
- ⚠️ **The UI suite requires an ASCII-capable input source, and the machine's can change under you.**
  XCUITest resolves `typeKey("s")` through the LIVE input source, so on a Russian/Greek/Hebrew layout the
  synthesized event no longer carries the physical key the app resolves chords by (issue #306 policy, see
  [[keymap]]), and every letter chord dies six `pressUntil` retries later. Named keys are unaffected, so
  ⌃␣ still enters normal mode while `nmap s` never fires, and ⌃A>S never completes: it reads as a broken
  keymap, or as whatever else changed that day. `launchForUITest` now fails immediately instead, and
  `UndoCloseShortcutTests` skips on the same reading. macOS remembers an input source PER APP, so merely
  activating an agterm build that last ran under a non-Latin layout can switch the machine before a run;
  read it the way `KeyboardLayout.isASCIICapable` does
  (`TISCopyCurrentKeyboardLayoutInputSource` + `CFBooleanGetValue`), never the menu bar glyph.
- Use retrying `settingsControl(tab:control:)`; reopen can leave a non-key Settings window that drops the
  first tab click.
- Add UI coverage for UI behavior. For Metal/transient state absent from AX, assert an observable side
  effect, such as `tty > <file>` identifying the focused pane.
- `AppearanceFlipUITests` uses XCUITest-only `debug.appearance light|dark`, which sets
  `NSApp.appearance` and posts `.agtermSystemAppearanceChanged`; production uses app-level KVO.
  Refuse the command outside XCUITest and exempt it from keep-in-sync. Set a starting side, assert the
  echoed response, and poll the bare form's last-applied side. To catch a zoom-clearing misroute, sample
  `fontSize` continuously: current libghostty `update_config` does not reset runtime zoom, so CELL_SIZE
  can repersist it about 0.4 seconds after a brief nil.
- For OSC titles, type literal `printf '\\033]2;TITLE\\007'; cat`; let the session shell expand escapes.
  `cat` prevents the next prompt from clearing the title. Raw ESC/BEL bytes can trigger line-editor
  keystrokes. Read display name from the `session-row` static text's value, and subtitle from
  `palette-subtitle`'s value. Assert cwd against `/Users/`, not the runner's different home.
  `tree --json` exposes raw `title`; see `SessionSubtitleUITests` and
  `ControlAPIUITests.testTreeExposesOscTitle`.
- `ReorderUITests.dragRow` must select the source and drain the run loop, drag between normalized
  coordinates, and use mouse-native
  `click(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`. Element-to-element targets the
  recycled cell text; touch `press(forDuration:thenDragTo:)` delivers AppKit dragging intermittently.
  Run one drag per fresh launch. For failures, log `validateDrop`/`acceptDrop`: no events means the
  gesture never started; wrong `dest` means delegate resolution. Query the last 90s of unified logs.
- **Never run XCUITests while the user is testing a handed-off build.** They activate apps and send real
  keyboard/mouse events even in the background. Run them before handoff or after the user finishes.
  Host-free tests are safe.
- Always run `cd agtermCore && swift test`, normally about 0.2 seconds. Ask before XCUITest.
  The suite is about 75 seconds per
  class and 460 seconds for all 77; target exact affected methods with one
  `-only-testing:agtermUITests/<Class>/<method>` each. A behavior-preserving extraction with unchanged AX
  identifiers needs `make build` and lint, not UI tests. Recommend a class/broader run only for changed
  cross-cutting behavior such as launch, signing/bundle, eager-deck, or scene/window wiring.
- After changing a test, run `build-for-testing`; app-only `xcodebuild build` leaves a stale XCUITest
  bundle for `test-without-building`. A stale assertion may appear as `Executed 0 tests` plus restart and
  a named failure. Read the xcresult failure message, or use `xcodebuild test`.
- Palette identifiers propagate to text children, so a subtitle row can have duplicate matches whose
  `firstMatch` title is not hittable. Click
  `allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch`, but keep lazy `firstMatch` for
  existence waits; eager resolution before the row exists breaks
  `testPickKeepsKeyboardAfterClosingBuiltInPalette`. Fast `Not hittable: StaticText` is this issue, not
  the slow occlusion timeout. See `ControlPickUITests.clickPaletteRow`.
- For `.segmented` Picker, click the labeled descendant. For a default/menu Picker, click the picker then
  `app.menuItems["X"]`. Update the interaction when changing style; see the Settings picker tests.
- XCUITest-synthesized clicks do not fire a SwiftUI `Button` inside `NSPopover`; a real click makes the
  popover key. Test open and contents, then verify selection manually and through host-free APIs. Put AX
  ids on rows, not a parent that would override descendant ids. Retry opening only while no row is
  visible, since the popover can dismiss before the first snapshot. See the recent/attention tests and
  [[menu-actions]].
- `Failed to synthesize event: Timed out while synthesizing event` or `Unable to find hit point` after
  about 90 seconds, with no assertion, indicates window occlusion such as HazeOver. The observed keyboard
  failure occurred about 64 seconds after synthesis began and the same test passed in about 13 seconds
  without HazeOver. Quit overlays and
  clear covered/minimized/other-Space windows before debugging the test. FB11763863 instead has no
  window/AX tree.
- `XCUIApplication.terminate()` does not call `applicationWillTerminate`. Use ⌘Q plus
  `wait(for: .notRunning, timeout:)` for restore-command or quit-flush tests; XCUITest auto-skips the
  quit-confirm modal. `MultiWindowUITests` survives hard termination only because structural saves
  already persist the open set. Use a temp file, not unreliable `NSLog`, to instrument the callback.
- Dismiss Settings by the close button of `app.windows.containing(.any, identifier: <a control on the
  tab>)`. ⌘W also closes it and leaves the deck alone (issue #401, pinned by
  `SettingsUITests.testCommandWClosesTheSettingsWindowNotTheSession`), but only while Settings is KEY —
  the reopen path above can leave it open and non-key, where ⌘W reaches the terminal window behind it
  and takes a session with it.
- `ghostty_surface_foreground_pid` is `tcgetpgrp`, so it returns the foreground process GROUP id. Under a
  job-control shell that leader IS the program; a `--command` pane has no such shell and its leader is
  unreadable setuid-root `login`, which is why the tree read descends to the leader's children and the
  restore capture does not (see [[control-api]]). Restore skips only a known idle
  shell with no payload arguments except flags; shell scripts and `sh -c` payloads are captured. Use
  blocking `tee <file>` as the e2e marker and prove relaunch by delete/recreate.
  `RestoreCommandUITests.testRestoreReRunsShellScriptWrapper` uses `sh -c 'tee ...; true'` so `sh` remains
  foreground. Do not execute a script from the runner's sandboxed temp dir; the app can write there but
  cannot exec it.
