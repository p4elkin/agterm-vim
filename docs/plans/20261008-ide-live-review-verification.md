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
