---
worth: yes
where: agterm/Views/Palette.swift:391
added: 2026-08-11
---
# the palette row's own identifier clobbers `palette-badge` and `palette-subtitle`

`PaletteRow` puts `.accessibilityIdentifier("palette-item-\(item.id)")` on the whole row (Palette.swift:391),
above two children that carry identifiers of their own: the subtitle text (`palette-subtitle`,
Palette.swift:364) and the badge capsule (`palette-badge`, Palette.swift:376). A SwiftUI identifier on a
parent propagates down and overrides its descendants' — the same trap already recorded at
`agterm/Views/WindowContentView+RecentSessions.swift:61`, where the popover container deliberately carries
no identifier so the per-row `recent-session-row` ids survive. So both child identifiers are gone from the
accessibility tree and every row element answers to `palette-item-<id>` instead. The note in
`.claude/rules/ui-tests.md` about `palette-item-<id>` matching several elements per row is the same effect
seen from the other side.

The row identifier landed in `6b6323e` (native control picker, #316, 2026-07-29). `palette-subtitle` is from
`6b17182` (2026-06-27) and `palette-badge` from `c730e7e` (2026-06-23), so both worked for about a month and
then stopped. Nothing caught it: the UI suite does not run in CI (`.github/workflows/ci.yml` runs
`swift test` only), and the two tests that read these identifiers were not run again until 2026-08-11.

Three confirmed failures, all run on 2026-08-11:

- `agtermUITests/KeymapUITests.swift:39` — `testCustomCommandShowsBadgeInPaletteAndRuns` waits for
  `palette-badge` in the action palette and times out. Its sibling
  `testCustomCommandsPaletteShowsCustomOnlyWithoutBadge` still passes because it asserts the badge is
  ABSENT and finds the row by label, not by identifier.
- `agtermUITests/SessionSubtitleUITests.swift:45` and `:64` — both assertions consume
  `currentPaletteSubtitle()`, whose `waitForExistence` on `palette-subtitle` at `:94` fails, so the helper
  returns its literal `""`. Both messages end in `got ` with nothing after. The 29.5-second runtime of the
  first is the 10-second poll running twice. Earlier assertions in both tests pass with
  `continueAfterFailure = false`, so the session is alive and the OSC title has arrived one line before the
  failing read — this is the identifier, not timing and not a dead shell.

`XCUIApplicationSidebarIsolation.swift:50-53` corroborates independently, written by someone watching real
runs after the row identifier landed: a row WITH a subtitle "answers to it twice". A row matching twice and a
row without a subtitle matching once means the subtitle text is answering to `palette-item-<id>`.

The fix has to keep `palette-item-<id>` addressable, because `ControlPickUITests` (21 sites) and
`XCUIApplicationSidebarIsolation.paletteRow(_:)` click rows through it.

Preferred: make the row a real container, one line above the identifier at `Palette.swift:391`.

```swift
.accessibilityElement(children: .contain)
.accessibilityIdentifier("palette-item-\(item.id)")
```

Both `paletteRow(_:)` and `ControlPickUITests.clickPaletteRow` query `descendants(matching: .any)`, so a
container of any element type still resolves.

REJECTED: moving the identifier onto the title text. `ControlPickUITests.swift:506-508` records that the
title child is not hittable because the row owns the tap target, so after that move `clickPaletteRow` would
have only a non-hittable leaf and would fail with `Not hittable: StaticText`.

⚠️ The risk is the row's accessibility shape. If hittability moves from the container to the title leaf,
`clickPaletteRow`'s hittable-match filter finds nothing. The contained answer is a coordinate click, which
ignores hittability:
`matches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()`.

Re-run to prove the fix: `SessionSubtitleUITests` (both), `KeymapUITests/testCustomCommandShowsBadgeInPaletteAndRuns`
and `/testCustomCommandsPaletteShowsCustomOnlyWithoutBadge`, then the whole of `ControlPickUITests` and
`PaletteUITests` — that is where an accessibility-shape regression lands. Two comments go stale with the fix
and should be corrected in the same commit: the "answers to it twice" note above, and
`ControlPickUITests.swift:506-508`.
