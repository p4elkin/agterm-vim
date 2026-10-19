---
worth: yes
where: agtermCore/Sources/agtermCore/AppStore+RemoteAsk.swift:36
added: 2026-10-19
---
# a re-offered form ask vanishes when the new presenter lacks ask.form

The fork's `reofferRemoteAsk` empties the session's ask slot (`session.releaseAsk()`) and then calls
`presentAsk`, ignoring its answer. Before the 2026-10-19 upstream merge `presentAsk` could return nil only
with no presenter, which `reofferRemoteAsk` had already ruled out. Upstream #778 added a second nil:
a form or `cancelButton` ask (`PresentationAsk.needsFormSupport`) goes only to a presenter whose hello lists
`ask.form`, and only when it `fitsFrames()`. That nil now lands after the slot was emptied.

## What happened

Not reproduced; derived from reading `reofferRemoteAsk` and `presentAsk` after the merge.
An agent on the origin runs `agtermctl ask --input line --title "Branch name?"`. The ask goes to Mac A,
which presents the row and lists `ask.form`. Mac B, running a build from before #778, takes the presenter
role. `onPresenterChanged` calls `reofferRemoteAsk`: it releases the ask, `presentAsk` returns nil because
B's hello has no `ask.form`, and nothing re-opens the slot. The tree shows no `ask`, `AskRegistry` still
holds the id, and the `agtermctl ask` caller polls `pending` with no `cancelled`/`presentation-lost`
ever arriving. The same happens on the headless origin, which calls it with `includeWaiting: true`.

`control-api.md`'s Remote sessions ask paragraph states both rules, re-offer and `ask.form` gating, and
says nothing about where they meet.

Fix, a choice still to make: check eligibility before releasing (keep the ask local, as a fresh open
would), or on nil take it back the way a lost presenter does (`takeBackRemoteAsk` / `failHandback`).
Either needs an `AppStoreRemoteAskTests` case with a presenter whose hello omits `ask.form`.
