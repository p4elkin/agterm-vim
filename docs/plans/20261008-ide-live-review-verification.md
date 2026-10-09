# IntelliJ live review: verification record

Results of the agterm-vim plan's probe and manual checks. One line per check.

## Probe (Task 1), 2026-10-09

Setup: a throwaway Debug build (never committed) that fits the IDE frame to the left half of the slot,
standing in for a left pane overlay. Isolated state `/tmp/agp`. Scratch repository with one commit that
adds, modifies, deletes and renames a file, opened with today's `--rebased`. Window placement was measured,
not judged by eye: a bridge timer wrote every showing AWT window with its bounds and owner. The frame held
`x=221 w=849` of a slot about 1698 wide. `screencapture` could not capture the display from this session,
so the first run had no screenshots and opened the file diff through `ShowDiffAction.showDiffForChange`
rather than a click. A second run of the same build was checked by hand (Sasha, with a screenshot), below.

- [ ] probe-dialog: fail — rejected option, kept as an unfitted baseline: the probe never fitted dialogs to the half. `VcsDiffUtil.showChangesDialog` opened a `MyDialog` owned by the project frame at `x=457 w=376`, inside the left half only because it centres on the frame; nothing fits it to a pane, and a modal or larger dialog would not be held there. A file diff opened from it went to an editor tab.
- [x] probe-tab: pass — a `ChainDiffVirtualFile` over a `ChangeDiffRequestChain` opened with `FileEditorManager.openFile` became an editor tab in the frame (title `added.txt`); no other window appeared. Opening a file diff the double-click way (`ShowDiffAction.showDiffForChange`) also stayed in a tab. The only showing window kept `x=221 w=849`. By hand: the diff tab showed inside the left half; in the Git log's file list a double click opened the plain file (this build's Log jumps to source on double click) and ⌘D (Show Diff) opened a two-sided diff, each as a tab in the left half with no new window. After a click in the right half, which in this probe is the gray session-wide overlay area and holds no shell, typed letters did not reach the IDE, and AWT reported no focused window.
- [x] probe-hide: pass — with the diff tab open, and again with the changes dialog open, the bridge `hide` left no showing window at all; `show` brought back the frame (and the dialog, which is owned by the frame) at the same bounds.
- [x] probe-choice: pass — tab
- [x] probe-cleanup: pass — both instances (pids 63820 and 35024) stopped with SIGTERM; `lsappinfo list | grep -A4 agterm.debug` showed nothing.

## Manual verification (Task 16), 2026-10-09

Setup: a Debug build of the lead branch, isolated state `/tmp/agt-lr` (Sasha's keymap copied, toggle chord ⌘⌃V),
CLI on `--socket /tmp/agt-lr/agterm.sock`. Scratch repository `/tmp/agt-repo`: `main` holds the base; `feature`
adds, modifies, deletes and renames a file; the working tree has an edit to `a.txt` and a staged new `wt-added.txt`.
Commands and read-backs were run here; what is on screen and where keys go were checked by Sasha.

- [x] live-pane-open: pass — `--pane left --diff HEAD.. --working-tree --on-close …` covered the left pane only; the right shell stayed visible and took typing.
- [x] live-view-opened: pass — the open's request read `view.state: opened`, detail `2` (one modified, one staged file); `rebased.port` was `63343`.
- [x] live-diff-inside: pass — file diffs opened from the list stayed inside the left pane.
- [x] live-working-tree-direction: pass — `main.. --working-tree` read detail `6`; `wt-added.txt` was listed as added, with the empty base on the left and the working copy on the right.
- [x] live-empty-range: pass — `HEAD..HEAD` opened nothing and read `opened`, detail `0`.
- [x] live-file: pass — `--file a.txt:3` put the caret on line 3; read `opened`.
- [x] live-git-error: pass — `nosuchref..` showed no dialog and read `failed`, detail `bad revision 'nosuchref'`.
- [x] live-resize: pass — dragging the divider and moving the window kept the frame on the left pane.
- [x] live-floating-over: pass — a 60 % program overlay hid the pane IDE; closing it brought the IDE back, with no marker.
- [x] live-toggle: pass — the chord hid the IDE, the left terminal took a click and typing, the tree read `hidden: true`, no marker; the chord again showed the same IDE. Session-wide at `--size-percent 60`: hidden left no panel, frame, wash or text, and the chord brought it back.
- [x] live-toggle-cli: pass — `session rebased toggle` answered `hidden`, then `shown`, and the tree's `hidden` followed.
- [x] live-hidden-view: pass — `show --file modified.txt:2` while hidden read `queued`; the next chord showed it at line 2 and it read `opened`.
- [x] live-swap: pass after a fix — the first runs left the swapped-to pane gray while the tree read `shown`: the old pane's slot reported leaving the screen before the new slot was in the window, so the host hid and showed the frame in one turn and AWT left it hidden. Fixed in `49125312`; then two swaps moved the IDE right and back left, and the chord still worked.
- [x] live-focus-pane: pass — with the right shell focused, ⌃1 and `session focus left` each made the IDE key and it took typing. Toggle-show with the IDE's pane focused took the keys once; with the right pane focused the keys stayed there; while another session was selected typing stayed there, and switching back did not pull the keys into the IDE. ⌘W from the right shell showed the dialog naming the review, and Cancel left everything; hidden, ⌘W showed the same dialog. No marker.
- [x] live-scratch-over: pass — ⌘J hid the IDE and showed the scratch, ⌘J again brought the IDE back. ⌘J works only after focus leaves the IDE: while the IDE is key it takes ⌘J itself (Insert Live Template); only the toggle chord passes through.
- [x] live-refusals: pass — a second open with `--on-close` was refused (`a Rebased overlay is already open in this session; --on-close needs a new one`) and the tree was unchanged; `close --overlay <random uuid>` was refused (`no matching Rebased overlay`).
- [x] live-close: pass — `close --overlay <id>` closed the IDE and the on-close command ran once (also once for `close --pane left`).
- [x] live-frame-closed: pass — File ▸ Close Project inside the IDE closed it, the left shell came back, and the command ran once.
- [x] live-quit: pass — a cancelled Quit left the instance and wrote no marker; a confirmed Quit ran the command once.
- [x] live-sites: pass — the font refusal reads `Rebased overlay has no terminal font size` on `--pane left` and `--pane right` works; the rest of the app sites (zoom target, dashboard cover, search) are covered by core and hosted tests, not checked by eye.
- [x] live-cleanup: pass — the instance quit through the menu; `lsappinfo` showed none of this worktree's instances.
