---
worth: later
where: agterm/Control/ControlServer+Zmx.swift
added: 2026-09-03
---
# Upstream's remote attach overlaps the fork's mirror job

Upstream v0.26.0 shipped `zmx tree <host>` and `zmx attach <host> <session>`: the app ssh's to another
Mac, reads its attachable zmx daemons, and creates a local session bound to one of them. A remote
session carries `Session.remoteHost`, is never persisted, and owns no local pane claims.

The fork reaches the same place from the other side. `agterm-zmx-mirror` makes one mosh row per remote
surface, pins `--cwd "$HOME"`, and writes the `mirrorsSession` pairing so overlay redirect knows which
workstation session a laptop row stands for. See [[overlay-redirect]].

Two mechanisms for "a row on this Mac showing a session on that one" is the default outcome nobody
chooses. Worth deciding, outside a merge, whether the mirror job should create its rows through
`zmx attach` instead of mosh, and what that would do to the pairing fields — a remote-attached row knows
its host natively, which is most of what `mirrorsSession` records. The parts that do not fall out of it
are the mirrored session's key and its per-pane cwd, which the redirect's `cd` needs.

Upstream #629 (merged 2026-09-19) widened the gap. A row created by `zmx attach` now also mirrors the
origin's status, notifications and HUD to the viewer, over a presentation stream `zmx present` opens.
`ControlServer+Zmx.attachRemoteSession` is the only place that arms it, so a mirror-job row — made with
`session new --command`, never through `zmx attach` — gets none of it. The fork's own
[[overlay-redirect]] left the status HUD out on purpose and says it "still appears on the workstation";
that is still true of the mirror path, and no longer true of an upstream attach. So the choice is now
also about which of the two mirroring paths carries the origin's panel, not only about the pairing
fields.

Not a defect. Nothing in the merge broke, and both paths work today.
