---
worth: yes
where: agtermCore/Sources/agtermctlKit/SocketClient.swift:connect
added: 2026-09-14
---
# a refused connect reads as agterm not running

`SocketClient.connect` answers every failed `connect` with `is agterm running?`. On Darwin a live
listener whose backlog is full refuses with the same `ECONNREFUSED` as a socket nobody listens on, and
the app's backlog is 8 with one serial accept thread, so a wedged main thread (#606) or one stalled
client makes a running app report as absent. `ControlServer.acquireOwnership` already documents the
ambiguity and holds an exclusive `flock` on `<socket>.lock` for exactly this reason; the CLI could probe
that lock after a refused connect and say the app is running but not answering. Surfaced by #606, where
the reporter read the refusal as the app being gone.
