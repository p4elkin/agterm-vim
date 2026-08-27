---
worth: later
where: agtermCore/Sources/agtermCore/WindowLibrary.swift:365
added: 2026-08-27
---
# the pending-pair reset is hand-rolled in three places instead of owned by Session

`clearPendingForegroundCommands()` (`Session.swift:638`) owns two assignments,
`pendingForegroundCommand = nil` and `pendingSplitForegroundCommand = nil`. Three places write that pair
inline instead of calling it: `loadStore`'s failed-strip disarm (`WindowLibrary.swift:365`),
`recoverOrphanedWindows`' orphan disarm (`:634`), and `clearPendingRestoreOverrides()` itself
(`Session.swift:659`), which spells the pair out alongside the two restore slots.

This is the same shape as the capture-slot item PR #490 closed, one abstraction level down: the next
capture slot added, or a rename of either field, has to find three hand-written copies. Nothing
user-visible turns on it today and all three sites are correct as written, which is why this is filed
rather than fixed.

Any consolidation has to keep three things intact. `recoverOrphanedWindows` needs its `where` guard and
its `stripped` flag, since it only saves when something actually changed. `clearPendingRestoreOverrides()`
must keep clearing the two restore pending slots that `clearPendingForegroundCommands()` does not touch.
And no site may widen to the persisted fields, which `.claude/rules/settings.md:170` forbids.
