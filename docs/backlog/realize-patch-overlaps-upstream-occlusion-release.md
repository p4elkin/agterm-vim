---
worth: later
where: agterm/Ghostty/GhosttySurfaceView+Realize.swift:35
added: 2026-08-30
---
# the fork's surface-realize patch now overlaps upstream's occlusion release

The fork carries `patches/ghostty/0001-surface-realize-api.patch` and
`GhosttySurfaceView+Realize.swift` to free a hidden pane's swap chain through
`ghostty_surface_set_realized`. Upstream PR 492 landed its own release for the same memory, driven
by `ghostty_surface_set_occlusion` on the new `deckOnScreen` property, and moved `GHOSTTY_REV` to
`683d8db` where occlusion releases the Metal swap chain by itself. So both mechanisms now target the
same allocation on every hidden pane.

Two separate things to decide, and neither belongs in a merge:

- **Is the patch still worth carrying?** If occlusion already frees the chain at the current pin,
  the realize path buys nothing and the fork could delete the patch, the extension and the two
  properties. Carrying a libghostty patch has a standing cost: it broke on this merge's pin bump and
  needed a context rebase in `src/renderer/generic.zig`, and it will need one again on every bump.
- **If it stays, it is keyed on the wrong property.** `updateRealizeForVisibility` reads
  `deckVisible`, whose `holdsKey` term is focus ownership rather than visibility, so an inset quick
  terminal drops `deckVisible` on panes that are still on screen. Ten seconds later those panes are
  unrealized while visible: CoreAnimation keeps compositing the last frame, so a pane producing
  output freezes rather than blanks. `deckOnScreen` is exactly the signal upstream added for this,
  and re-keying is a one-line change plus a test.

Surfaced triaging the merge of upstream 82d6f17 into the fork. Not a regression from that merge —
the mis-keying predates it — but the merge is what made the overlap visible.
