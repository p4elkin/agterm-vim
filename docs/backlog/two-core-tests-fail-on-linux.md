---
worth: soon
where: agtermCore/Tests/agtermCoreTests/HudTests.swift:aFramelessPanelIsAsTallAsItsText, agtermCore/Tests/agtermCoreTests/ZmxReplayScriptTests.swift:interruptedPayloadStillExecsTheFinalShell
added: 2026-10-25
---
# Two agtermCore tests fail in the Linux gate on main

`swift test --no-parallel` on p4linux (swiftly Swift 6.2.4) fails with 3 issues at `main` 390c662d, in a fresh
`/tmp` clone. Both suites pass on the Mac. Both tests came in with upstream merges (303bf332, acfd06b4).

- `HudTests.aFramelessPanelIsAsTallAsItsText`: `HudLayout.markdownBody(for:grid:).lines` is `["- a", "- b"]` on
  Linux, the test expects `["• a", "• b"]`. Linux Foundation's markdown parsing likely does not turn list items
  into the presentation intent the Mac build reads. [Unverified]
- `ZmxReplayScriptTests.interruptedPayloadStillExecsTheFinalShell`, both forms: the fixture's `payload-log` under
  `/tmp/agterm-zmx-replay-<uuid>/` was never written. So the script under test never ran the payload, or ran it
  under a shell where the interrupt behaves differently.

The headless origin runs this code on Linux, so a HUD list can render with raw dashes there. Decide per test
whether the code or the test needs a Linux branch. Until then the Linux gate reads red for a reason that has
nothing to do with the change under test, so check this list before treating a red gate as new.
