---
worth: later
where: agterm/SettingsModel.swift:applyWindowSettings
added: 2026-10-26
---
# the recency dwell keeps its own seeding path beside upstream's applyWindowSettings

Upstream `6864e35a` replaced `applyAutoFollow(to:)` / `applyAutoFollowToAllWindows()` with
`applyWindowSettings(to:)` / `applyWindowSettingsToAllWindows()`, one seam that pushes every
per-window setting into each `AppStore`. The fork's recency dwell still has its own pair,
`applyRecencyDwell(to:)` / `applyRecencyDwellToAllWindows()`, and every site that seeds a store now
calls both.

## What happened

At the 2026-10-26 merge, `ContentView.resolveStore` and the scene `.task` in `agtermApp.swift` each
conflicted only because the fork's extra call sat next to the line upstream renamed. The resolution
keeps both calls side by side. Moving `store.setRecencyDwell(...)` into `applyWindowSettings(to:)`
would delete the fork's pair and both extra call sites, so the next upstream change to that seam
cannot conflict there. `setRecencyDwell` in `SettingsModel` would then call
`applyWindowSettingsToAllWindows()` like its upstream siblings.
