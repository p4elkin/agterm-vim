---
worth: later
where: agtermCore/Sources/agtermctlKit/SessionCommands.swift:204
added: 2026-08-18
---
# `--stdin` with invalid UTF-8 types nothing and still answers ok

`session type --stdin` decodes stdin with `String(data: data, encoding: .utf8) ?? ""`, so a single
invalid byte makes the whole payload empty and the command answers `ok` having typed nothing.
`quick type --stdin` is identical at `MiscCommands.swift:157`. Same false-ok family as #455, but
lower risk: it empties the entire payload rather than leaving a shortened prefix that still gets its
Return and executes.

The coherent fix is a local CLI rejection, something like `stdin must be valid UTF-8` for both
commands, since the API contract is text. That needs its own tests and its own public error string,
which is why it was kept out of #455 rather than folded in.

Surfaced while fixing #455; the NUL rejection there is at the dispatcher and does not touch this
path, which is client side.
