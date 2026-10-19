---
worth: later
where: agtermCore/Sources/AgtermHeadlessKit/HeadlessActions.swift:137
added: 2026-10-19
---
# headless status sounds never reach the presenting Mac

Upstream #775 (`989df5f0`) routes a `session.status` sound to the presenter: the Mac origin's
`setSessionStatus` calls `AppStore.presentStatusSoundRemotely`, which sends a one-shot `sound` frame when
the status pane follows. The fork's headless origin builds its own `setSessionStatus` and drops
`update.sound` entirely, so it never sends that frame. The plumbing (`PresentationSound`, the negotiated
`sound` kind, the viewer's `playRemoteSound`) now exists, which makes this a small adoption.

## What happened

Not reproduced; derived from reading `HeadlessActions.setSessionStatus` after the 2026-10-19 merge.
Claude Code in a p4linux session hits a permission prompt and its hook runs
`agtermctl session status blocked`. A Mac origin would send `sound(nil)`, the blocked-default marker, and
the presenting Mac would play its own Blocked sound. The headless origin applies the indicator and
answers ok; p4linux has no speaker and nothing is sent, so the viewing Mac shows the red glyph silently.

Fix: mirror the Mac's two lines in `HeadlessActions.setSessionStatus` (explicit sound, or the transition
into `blocked`), calling `store.presentStatusSoundRemotely`, plus a `HeadlessKit` test.
