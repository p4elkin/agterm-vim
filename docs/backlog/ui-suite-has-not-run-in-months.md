---
worth: yes
where: scripts/test-app.sh, .github/workflows/ci.yml
added: 2026-08-11
---
# nothing runs `agtermUITests`, and it has rotted

`scripts/test-app.sh` invokes `-scheme agtermTests`, and `project.yml` gives that scheme only the
`agtermTests` target — `agtermUITests` lives solely in the `agterm` scheme. So `make test-app` never ran a UI
test, and a `-skip-testing:agtermUITests` flag passed to it is a no-op. CI runs `swift test` only. On top of
that, XCUITest needs a macOS UI-automation authorization scoped to the process tree that answered the prompt
(`.claude/rules/ui-tests.md`), which had not been granted on this machine.

The result: the suite had not executed in months, and it accumulated failures nobody could see. Every
"all gates green" claim in that period covered `swift test`, `make lint`, `make release` and the hosted
`agtermTests` only.

Measured 2026-08-11 with the authorization granted, running `-only-testing:agtermUITests` alphabetically.
The run was stopped by hand after 20 of the classes, so this is a partial inventory: **246 passed, 9 failed.**

Three are one known defect, see
[the palette row identifier](palette-row-identifier-clobbers-child-identifiers.md):

- `KeymapUITests/testCustomCommandShowsBadgeInPaletteAndRuns`
- `SessionSubtitleUITests/testNamedSessionShowsOscTitleOnSecondLine`
- `SessionSubtitleUITests/testUnnamedSessionKeepsCwdOnSecondLine`

Six more are undiagnosed, each seen once:

- `AttentionButtonUITests/testAttentionButtonTogglesLiveFromSettings`
- `ClipboardPromptUITests/testReadPromptAllowDeliversClipboard`
- `ControlSidebarStatusUITests/testNotificationBadgeToggleHidesAndShowsBadge`
- `ControlWindowUITests/testDoubleClickHeaderHonorsNoneSetting`
- `ControlWindowUITests/testDoubleClickHeaderZoomsAndRestores`
- `FlaggedViewUITests/testFlaggedViewToggleSelectAndClear`

Classes from `G` onward were never reached, so the real total is higher.

Two traps found while getting the suite to run at all, both now handled in `launchForUITest` and recorded in
`.claude/rules/ui-tests.md`: a developer `~/.zprofile` that hands every agterm pane to a multiplexer and
exits kills the seeded session about 7 seconds in, and a non-Latin keyboard input source makes every
letter-chord assertion die six silent retries later while named keys keep working.

Worth deciding, in this order: whether `make test-app` should run the UI suite too (it would need the
`agterm` scheme and the authorization on whatever machine runs it), whether CI can run any of it, and only
then which of the nine failures are real defects rather than rotted tests.
