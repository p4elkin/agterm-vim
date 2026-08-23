---
worth: later
where: agterm/Views/WindowAccessor.swift:166
added: 2026-08-19
---
# the capture-slot reset is hand-rolled in two places instead of owned by Session

`willClose`'s non-last-window arm nils `foregroundCommand`, `splitForegroundCommand` and the pending
fields inline, spelling out the same reset `ControlServer.clearRestoreCommands()` already writes at
`:492`. `Session` is where that belongs: `clearPendingForegroundCommands()` (`Session.swift:627`) and
`clearPendingRestoreOverrides()` (`:635`) exist to group exactly this kind of reset with a doc line naming
the caller, and CLAUDE.md puts model mutation in agtermCore with the app target as a side-effect adapter.
The next capture slot added has to be threaded through two hand-written copies, which is the same miss
PR #452 is fixing in `closeSplit`, where `splitForegroundCommand` was left out because the clearing
knowledge was scattered rather than owned.

The second copy arrives with PR #452 and the `where` line above resolves only once that merges; the item
is moot if it does not. Deferred rather than asked of the contributor because the fix adds a method to
shared agtermCore code and edits a call site he did not come to touch, and the current code is correct as
written.

Any consolidation has to keep the two sites' scopes distinct, one store's sessions versus
`library.allOpenSessions()`, and clear the persisted and pending pairs together, since
`.claude/rules/settings.md:164` forbids clearing the persisted fields alone.
