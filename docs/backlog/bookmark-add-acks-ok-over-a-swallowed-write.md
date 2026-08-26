---
worth: later
where: agtermCore/Sources/agtermCore/BookmarkCenter.swift:58
added: 2026-08-27
---
# session.bookmark.add answers ok when the bookmark file never reached disk

`BookmarkCenter.persist()` is `try? persistence.save(store)`, so an unwritable
`bookmarks.json` is swallowed. `ControlServer+Mark.addSessionBookmark` then returns
`ok: true` with the new bookmark's id. The bookmark is real in memory and gone at the
next launch, and the caller was told it landed. `session.bookmark.remove` and the
close-time `dropSession` take the same path.

The comment there calls it "best-effort like `AppStore.save()`", which was true when it
was written. Upstream has since built the other half: `AppStore.saveChecked()` and
`WindowLibrary.saveAllOpenChecked()` return whether the write landed, and PR #452 /
commit c664db9 adopted them exactly where a control command's ack claims durability —
`restore.capture` and `restore.clear` now refuse rather than answer ok over a failed
write. Bookmarks are persisted on purpose (surviving a restart is the whole feature), so
the same shape applies.

Adopting it means a checked `persist()` and an error response on the add/remove paths;
`dropSession` stays best-effort, having no caller to answer. Filed from the 2026-08-27
upstream merge as an adopt-from-upstream item, not as merge fallout.
