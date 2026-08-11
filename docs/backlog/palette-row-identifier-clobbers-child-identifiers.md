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

Two known failures:

- `agtermUITests/KeymapUITests.swift:39` — `testCustomCommandShowsBadgeInPaletteAndRuns` waits for
  `palette-badge` in the action palette and times out. Its sibling
  `testCustomCommandsPaletteShowsCustomOnlyWithoutBadge` still passes because it asserts the badge is
  ABSENT and finds the row by label, not by identifier.
- `agtermUITests/SessionSubtitleUITests.swift:94` — `currentPaletteSubtitle()` reads
  `app.staticTexts["palette-subtitle"].value` and should be returning `""` for the same reason. Unverified:
  the class has not been run since the row identifier landed. Run it first — it is the cheapest confirmation
  of the diagnosis, and it decides whether the fix has one victim or two.

The fix has to keep `palette-item-<id>` addressable, because `ControlPickUITests` and
`XCUIApplicationSidebarIsolation.paletteRow(_:)` click rows through it. Candidates, none verified:

- move the row identifier onto the title text, leaving the container without one, as the recent-sessions
  popover does. Row clicks still work — `ControlPickUITests.clickPaletteRow` already picks the first
  hittable match rather than the container.
- make the row a real container with `.accessibilityElement(children: .contain)` before the identifier, so
  children keep their own identity. This changes the row's accessibility shape, so the pick tests need
  re-running.

Either way the change touches the element every palette test addresses, so it needs the pick and control
suites re-run, not just the two tests above.
