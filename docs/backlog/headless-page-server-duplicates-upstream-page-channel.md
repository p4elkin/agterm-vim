---
worth: later
where: agtermCore/Sources/AgtermHeadlessKit/PageServer.swift
added: 2026-10-22
---
# The headless page server duplicates upstream's page channel

Upstream #793 (merged 2026-10-22) shows an origin's `--html` page on the presenting Mac. The Mac runs
`ssh -T <origin> agtermctl session overlay page-serve <token>`, and the origin serves the page's files and
bridge requests over that one connection, bounded by the page's grant. No port listens anywhere.

The fork's headless origin solved the same problem first and its own way: `Headless.servePage` publishes the
file's folder under a token, `PageServer` serves it as plain http on `AGTERM_HEADLESS_PAGE_HOST:19510`, and the
open is forwarded as a `--url` page. See [[headless-origin]].

## What happened

Not reproduced; derived from reading `HeadlessActions.openServedPage` and `.claude/rules/headless-origin.md`.
`agtermctl session overlay open --html report.html` on a p4linux row reaches the Mac as a `--url` page at
`http://p4linux.<tailnet>.ts.net:19510/<token>/report.html`. Today that costs: a page host seeded in
`~/.config/agterm-headless/env`, an ATS exemption for `ts.net` in `agterm/Info.plist`, no `--chromeless`, no
theme defaults, and no bridge (`agterm.*` calls from the page). The merge classified `session.overlay.page.serve`
as refused on a headless origin (`ForwardPolicy`, "a Mac feature"), so nothing uses the new channel there yet.

Worth deciding outside a merge whether the headless origin should hand pages over through upstream's
`PresentationPage` / `page-serve` path instead. That would delete `PageServer`, `HeadlessPages`, the page-host
setting and the ATS exemption, and bring the bridge to headless pages. The cost is implementing the origin side
(`claimPageServe`, `AppStore+RemotePage`) without AppKit on Linux.
