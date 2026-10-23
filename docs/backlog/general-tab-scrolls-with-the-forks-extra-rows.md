---
worth: later
where: agtermUITests/SettingsUITests.swift:assertGeneralTabFits
added: 2026-10-10
---
# the General settings tab scrolls with the fork's extra rows, and upstream's fit test says it must not

Upstream `292f3289` ("keep the General tab from scrolling") found that one added row, "Open links in",
made the General tab scroll in the fixed 540x680 window. It removed the `Ghostty Config` section header
to win the space back and added `assertGeneralTabFits`, which scrolls the tab and fails if the closing
"Also loads …" hint moves.

## What happened

Not reproduced; derived from reading the merged `agterm/Views/SettingsView.swift` during the
2026-10-10 upstream merge. Upstream fitted the tab to its own rows. The fork's Sessions section carries
four more: `NewSessionHostField` with its hint, and the `settings-rebased-app-path` IDE app field with
its hint. Removing one section header cannot absorb four rows, so the tab almost certainly still scrolls,
and `testFlaggedViewLayoutPickerPersists` and `testLinkOpenModePickerPersists` should fail on
`"the General tab should not scroll"`. Upstream's commit also says the earlier fit check passed while the
tab scrolled, so the fork tab was probably scrolling before this merge too.

No merge gate notices: `make test-app` runs `agtermTests` only, never `agtermUITests`
(see `ui-suite-has-not-run-in-months.md`). Same root cause as
`settings-window-height-sized-without-the-forks-extra-section.md`, on a different tab.

To confirm: `-only-testing:agtermUITests/SettingsUITests/testFlaggedViewLayoutPickerPersists`.
If it fails, the choice is moving the fork's rows to another tab, dropping their hints, or a taller frame.
