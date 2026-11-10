---
worth: later
where: agtermCore/Sources/agtermCore/ControlProjection.swift
added: 2026-11-10
---
# the fork's `remoteSession` tree field duplicates upstream's `remoteSessionID`

Upstream ebc66405 (merged 2026-11-10) added `remoteSessionID` to the session node and to the
`remote.opened` / `remote.closed` payloads. It is stored on `Session` at construction. The fork already had
`remoteSession` on the node, read from `remotePresentation.binding.remoteSessionID` for a bound remote row.
The merge kept both, and the fork's attach and restore path (`insertRemoteRow` in `ControlServer+Zmx.swift`)
now passes `remoteSessionID: row.remoteSessionID` to `addSession`, so the two carry the same value.

## What happened

Not reproduced; derived from reading `AppStore.controlTree` and `insertRemoteRow`.
A row attached from p4linux with origin id `s1` reads in `agtermctl tree --json` as
`"remoteSession":"s1"` AND `"remoteSessionID":"s1"`. Upstream's field also covers replica page rows
(`addReplicaPageRoot` / `addReplicaPageCompanion`), so it is the wider of the two.

Retiring the fork's field is fork code to delete, but it is not local: `~/dev/agterm-agents/bin/`
`agterm-row-to-window`, `agterm-row-origin`, `agterm-headless-ctl` and `agterm-open-path` read
`remoteSession` from the tree. Move them to `remoteSessionID` first, then drop the fork field, its
`AppStoreTreeProjectionTests` cases, and its bullets in `.claude/rules/control-api.md` and the skill's
`reference.md`. Check first that a headless row's `remoteSessionID` is set on every path that sets
`remoteSession` today.
