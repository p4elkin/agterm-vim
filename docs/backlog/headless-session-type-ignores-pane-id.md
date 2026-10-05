---
worth: yes
where: agtermCore/Sources/AgtermHeadlessKit/HeadlessActions.swift:369
added: 2026-10-05
---
# headless session.type ignores --pane-id

Upstream v0.35.0 (#698, `eab672be`) added `--pane-id` to `session type` and carried it to
`ControlSessionTypeOptions.paneID`, resolved on the Mac through `Session.paneAddress(token:pane:)`.
The headless origin's `HeadlessActions.typeSession` still reads only `options.pane`, so the token is
dropped without an error. `readSessionText` beside it resolves the token but still falls back on an
unknown one, where the Mac now refuses it without `--pane`.

## What happened

Not reproduced; derived from reading `HeadlessActions.typeSession` after the 2026-10-05 merge.
An agent in the right pane of a split session on the Linux origin runs
`agtermctl session type --pane-id "$AGTERM_PANE_ID" 'ls\n'`. `ForwardPolicy.kind` serves
`session.type` locally, `typeSession` takes `options.pane ?? .left`, and the text goes into the LEFT
pane's daemon. The same call against a Mac row types into the right pane.

Fix: switch both headless reads to `session.paneAddress(token:pane:)` and answer
`.unknownToken` the way `ControlServer.unknownPaneID` does, with a `HeadlessSplitTests` case for each.
