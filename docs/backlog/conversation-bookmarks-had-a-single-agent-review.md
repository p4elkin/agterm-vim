---
worth: yes
where: agtermCore/Sources/agtermCore/{TurnMark,Bookmark,BookmarkStore,BookmarkCenter,BookmarkPersistence}.swift
added: 2026-08-21
---
# Conversation bookmarks shipped on a single-agent review, and wants a real one

The bookmarks feature (`d617acd`, 33 files, +1694/-64) was reviewed by ONE agent, not the usual revmux
panel, to save quota on the day. That one pass was good — it found four real defects, all confirmed
against the code and fixed in `16d9720` before the merge:

- the bookmark drop hung off `.sessionClosed`, which a soft close emits when the undo grace STARTS, so
  undoing a close lost the session's bookmarks from memory and from disk
- the agent-hooks merge treated "this entry already invokes our wrapper" as "up to date" and skipped the
  event, so every existing install would never have run `session.mark` at all
- the mark was written to `session.surface` unconditionally, so an agent in a split wrote its marks over
  the other pane while `bookmark go` searched the focused one
- dedup keyed on session and turn alone, so after a restart a repeated turn number overwrote the earlier
  bookmark's prompt — the only thing that survives a restart, the mark itself being gone

What a single pass does NOT give, and why this is `yes` rather than `later`:

- **no cross-source corroboration.** On the attention pill the same week, the one real bug was found
  independently by two agents and the layout problem by two more, and that agreement is what made them
  credible. Here every finding rests on one voice.
- **no adversarial verify stage.** revmux normally has a second stage try to REFUTE each finding before
  reporting it, and separately surfaces `immaterial` and `pre_existing`. None of that ran.
- **no codex peer**, so a second model's blind spots were never covered.

The reviewer was also handed a list of "findings that would be wrong" — the deliberate exclusions — which
is right for a one-shot pass and is exactly the kind of framing that can suppress a real finding sitting
next to a rejected idea.

## What a proper round should look hardest at

- the `go` side still resolves its own pane through `session.search`, so a jump works while you are looking
  at the pane you bookmarked in and not otherwise. Carrying the pane on the `Bookmark` and giving
  `session.search` a pane argument is the unfinished half of the split-pane fix.
- `BookmarkCenter.persist()` is `try?` like `AppStore.save()`, so a failing disk is silent. Fine for the
  snapshot; less obviously fine for the only copy of a turn's text.
- the `sessionDidFinalize` callback added in `16d9720` is new plumbing on `AppStore`. It fires from two
  paths and nothing else consumes it yet; a second consumer is where an ordering assumption would surface.
- `Bookmark.currentRun` is a process-wide `static let`. It is correct for one app instance and was never
  reasoned about across two instances sharing a state directory.

Not blocking anything: the feature works, its gates are green, and the four defects above are fixed.
This exists so nobody reads the merge as having had the review the pill got.
