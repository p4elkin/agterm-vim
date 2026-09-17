---
worth: maybe
where: agterm/Views/SettingsView.swift:AgentStatusSettingsView
added: 2026-09-12
---
# the Settings window height was sized without the fork's extra section

Upstream `1cfc300` ("fit the Interface and Agent Status tabs in the window") raised the fixed Settings
frame from 540x640 to 540x680 and deleted the `SettingHint` under the Typing picker, so the Agent Status
tab fits. It measured upstream's tab. The fork's Agent Status tab has one Section more: `Recent sessions`,
a `Picker` plus a `SettingHint`, which backs the recency dwell. So the fork's tab is roughly two rows
taller than the one the 680 was fitted to.

Nothing catches this. The height is a literal, not a computed fit, and no gate renders the tab:
`swift test` and `make lint` are green, and `make test-app` asserts on accessibility identifiers rather
than on layout. `.claude/rules/settings.md` now states 540x680 because that line merged from upstream.

`maybe` because the overflow is unverified: it is derived from reading the two tabs, not seen. Checking it
means opening Settings > Agent Status in an isolated Debug instance and looking for a clipped Reset row.
If it clips, the scoped fix is a taller frame or dropping one of the fork's own hints; if it does not,
delete this item.
