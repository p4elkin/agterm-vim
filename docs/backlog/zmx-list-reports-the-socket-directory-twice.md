---
worth: later
where: agtermCore/Sources/agtermCore/ControlPayloads.swift:166
added: 2026-09-03
---
# `zmx list` reports the socket directory twice

Upstream's remote-sessions work added `endpoint` to the `zmx list` header, an optional
`ControlZmxEndpoint` carrying `executable` and `socketDirectory`. The fork had already added a top-level
`socketDirectory` string to the same header for the same reason: so an outside `zmx attach`, a plain
shell or a mosh session can set `ZMX_DIR` instead of recomputing the hash of the state directory.

The merge of 2026-09-03 kept both, because dropping the fork's field mid-merge would have changed the
wire shape the fork's own readers and `agterm-zmx-mirror` rely on. So `ControlZmxInventory` now has two
initializer arguments that mean nearly the same thing, and the JSON says the path twice.

Collapsing it means: drop the fork's `socketDirectory` property and initializer argument, point
`SocketClient`'s "socket directory:" line and the fork's tests at `endpoint?.socketDirectory`, and check
`~/dev/agterm-agents` for any script reading the top-level key. `endpoint` is optional on the wire, so
the readers need a fallback path for an older server, which is the one thing the fork's own field did
not need.
