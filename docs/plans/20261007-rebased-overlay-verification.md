# Rebased overlay: verification record

Task 0 ran `docs/plans/rebased-spike/` (`build.sh`, then `spike <state> <project> will|menu`) against
Rebased 1.1.20 (build 262.10968, JBR 25.0.4) on 2026-10-08. The menu probe ran in a Debug agterm built
from `7401b001` with a throwaway hook, isolated state `/tmp/agmp`, stopped by PID.

## Task 0

- [x] bridge: pass — `ready` reached the host through `hostEvent`, bound with `RegisterNatives` on the bridge object's class, after the host's `hello`.
- [x] zip-plugin: pass — the plugin built with JBR `javac` and packed with `/usr/bin/zip -r -X` into `lib/*.jar` loaded and published its bridge.
- [x] frame-owner: pass — the project frame was born at alpha 0 and revealed 0.15 s after adoption, with no IDE frame change before the reveal; an IDE `setBounds`, `MAXIMIZED_BOTH` and `ICONIFIED` each ended back on the slot; `toggleFullScreen:` on the IDE window was refused by `.fullScreenNone`. A resize from the IDE while visible is snapped back inside the same `didResize` notification (2 such moments per run; not watched by eye).
- [x] hide-show: pass — `setVisible(false)` orders the window out and drops the child link; `setVisible(true)` brings back the same `NSWindow`, which must be re-attached and refitted; it then becomes key.
- [x] full-screen: pass — the attached frame followed the host window into native full screen (child, on the active space, on the slot) and back out.
- [x] save-at-quit: pass — `saveAll` called inside `applicationWillTerminate` on the blocked main thread returned in 0.03–0.07 s with the edit on disk. Needed two fixes: model changes must run write-safe (not under `ModalityState.any()`), and `saveAllDocuments` returns before the bytes are on disk, so the bridge waits until each file matches its document.
- [ ] menu-swiftui: fail — SwiftUI does not replace a foreign `NSApp.mainMenu`, but on every state change (new session, new window) it rewrites the installed menu's items with its own (`Agterm, View, Navigate, Window, Help`), removing the foreign items. Swapping IntelliJ's menu in would let agterm corrupt it. Reinstalling SwiftUI's menu afterwards was fine: same items, New Window worked, reconcile restored the ⌘W split.
- [x] menu-inframe: pass — with `-DjbScreenMenuBar.enabled=false -Dapple.laf.useScreenMenuBar=false`, IntelliJ left the host menu installed while its frame was key and shows its menu as `MainMenuWithButton` in its toolbar (`IdeJMenuBar` with 10 menus behind it).
- [x] key-routing: pass — with the screen menu off and no router, ⌘F fired the host menu item and reached the IDE. A local key monitor that `sendEvent`s to the key AWT window and consumes the event delivered ⌘F to the IDE only. It must cover every AWT window: with an IDE dialog key, a frame-only router let ⌘F reach the host menu.

Also seen: a Messages dialog opened while the frame was visible was attached as a child of the host window. AWT aborts in a host with an empty main menu (`index <= [_itemArray count]`); agterm always has one.

## Task 13

Debug build of `pair/rebased-overlay-lead` (Tasks 0–11 landed), isolated state `/tmp/agrb`, real Rebased 1.1.20, project `/tmp/rbspike-proj`. Driven through the Debug `agtermctl`; window positions read with `CGWindowListCopyWindowInfo`. 2026-10-08.

- [x] live-open-full: pass — `session overlay open --rebased` started the JVM in agterm's process (`tree`: `jvm: running`); the project frame opened as a child of the agterm window, fitted to the slot, overlay `shown`.
- [x] live-open-floating: pass — `session overlay resize --size-percent 70` shrank the frame to a centred 748×503 inside the 1290×750 window.
- [x] live-window-move: pass — `window move` carried the frame with the window.
- [x] live-window-resize: pass — `window resize` refitted the frame to the new slot.
- [x] live-session-switch: pass — selecting another session took the frame off screen; selecting back put it on the slot again.
- [x] live-dashboard: pass — `dashboard --mru` hid the frame; `dashboard --close` brought it back.
- [x] live-one-frame-one-place: pass — a second session on the same repository took the frame (both overlays `shown`); closing it handed the frame back to the first session, now active.
- [x] live-close-session: pass — closing the only session showing the frame took it off screen and removed the overlay; `tree` kept `rebased.projects` for reuse.
- [x] live-tree-readback: pass — `tree` carried `rebased: {jvm, projects}` and the session's `rebasedOverlay: {project, state}` with `overlaySizePercent`.
- [ ] live-trust-dialog: open — on a fresh IDE config IntelliJ asks "Trust project?" (`TrustedProjectStartupDialog`) before any frame exists. The first build left it floating unattached; the fix attaches a dialog to the opening slot (`RebasedHostTests`). In the rebuilt instance the dialog appeared and was then gone before its attachment could be checked.
- [ ] live-ui-test: blocked — `ControlRebasedOverlayUITests` did not start: `Timed out while enabling automation mode` twice. The session host serving this shell started 2026-09-22 and its binary was replaced on 2026-10-06, the case `CLAUDE.md` describes; it needs Sasha.

Needs Sasha's hands in the same instance (keyboard, mouse, IDE actions): palette and zoom over the slot; agterm's menu intact with the IDE key and the IDE's main-menu button; ⌘F, ⌃Space, ⌃Tab, ⌃1 and ⌘Z after a close reaching the IDE; ⌘Q in the IDE quitting agterm; the toggle chord from inside the IDE; an IDE resize, zoom, full screen and minimize snapped back; a dialog while hidden; an unsaved IDE edit saved by agterm's quit; the app-view predicate sites from Task 2; TCC per service.
