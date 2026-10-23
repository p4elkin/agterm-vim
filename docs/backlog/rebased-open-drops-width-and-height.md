---
worth: later
where: agtermCore/Sources/agtermCore/RebasedOverlay.swift:185
added: 2026-10-23
---
# a Rebased IDE open drops --width/--height

Upstream v0.38.1 (#798) added per-axis point sizes to floating overlays. The dispatcher accepts them on
`session overlay open --rebased`, but the Rebased path never reads them, so the open succeeds and the
sizes are lost. `resize` does apply them to the same IDE, so open and resize disagree.

## What happened

Not reproduced; derived from reading the merged tree on 2026-10-23.

1. `agtermctl session overlay open --rebased --size-percent 80 --width 600` passes
   `dispatchSessionOverlayCommand`: no pane, a percent present, points valid.
2. `ControlSessionOverlayOpenOptions.points` carries `width: 600` to `ControlServer.openRebasedOverlay`,
   which calls `RebasedHost.openOverlay` with `sizePercent` only.
3. `seatRebasedOverlay` sets `overlaySizePercent = 80` and never touches `overlayPoints`, so the IDE
   opens at 80% on both axes and the answer is `ok`.
4. A following `session overlay resize --width 600` goes through `resizeOverlayInPoints`, which accepts
   it because `coverOverlayActive` counts the IDE, and the panel `RebasedSlot` sits in reads
   `overlayPoints`. Now the IDE is 600 pt wide.

Fix: either thread `points` through `RebasedHost.openOverlay` into `seatRebasedOverlay`, or refuse
`--width/--height` with `--rebased` in the dispatcher and the CLI.
