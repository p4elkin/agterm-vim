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
