# IntelliJ live review: verification record

Results of the agterm-vim plan's probe and manual checks. One line per check.

## Probe (Task 1), 2026-10-09

Setup: a throwaway Debug build (never committed) that fits the IDE frame to the left half of the slot,
standing in for a left pane overlay. Isolated state `/tmp/agp`. Scratch repository with one commit that
adds, modifies, deletes and renames a file, opened with today's `--rebased`. Window placement was measured,
not judged by eye: a bridge timer wrote every showing AWT window with its bounds and owner. The frame held
`x=221 w=849` of a slot about 1698 wide. `screencapture` could not capture the display from this session,
so there are no screenshots. "Clickable" for the right half is inferred: no showing window crossed into it.
The file diff was opened through `ShowDiffAction.showDiffForChange`, the call a double click runs, not by a
real click.

- [ ] probe-dialog: fail — rejected option, kept as a record. `VcsDiffUtil.showChangesDialog` opened a `MyDialog` owned by the project frame at `x=457 w=376`, inside the left half only because it centres on the frame; nothing fits it to a pane, and a modal or larger dialog would not be held there. A file diff opened from it went to an editor tab.
- [x] probe-tab: pass — a `ChainDiffVirtualFile` over a `ChangeDiffRequestChain` opened with `FileEditorManager.openFile` became an editor tab in the frame (title `added.txt`); no other window appeared. Opening a file diff the double-click way (`ShowDiffAction.showDiffForChange`) also stayed in a tab. The only showing window kept `x=221 w=849`.
- [x] probe-hide: pass — with the diff tab open, and again with the changes dialog open, the bridge `hide` left no showing window at all; `show` brought back the frame (and the dialog, which is owned by the frame) at the same bounds.
- [x] probe-choice: pass — tab
