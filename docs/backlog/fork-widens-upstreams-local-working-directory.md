---
worth: later
where: agterm/Commands/CustomCommandRunner.swift
added: 2026-09-11
---
# the fork widens upstream's local-working-directory guard instead of upstream doing it

Upstream 2e48202 (`feat(remote): expose session host and resolve local launch directories`) shipped its
own fix for the bug the fork had already fixed in `12c0b01`: a custom command spawned on a row whose
reported cwd is not a path on this Mac used to die inside `Process.run()`. The two fixes differ in one
condition, and the merge of 2026-09-11 kept both by layering the fork's on top of upstream's.

- Upstream: `Session.localWorkingDirectory(reported:homeDirectory:)` falls back to home only when
  `remoteHost != nil`. A local session keeps whatever path it reported, whether or not it resolves.
- Fork: the check is local existence alone, on every row, because a LOCAL row whose directory was
  deleted or replaced by a plain file throws in exactly the same place.

## What happened

Not reproduced since the merge; derived from reading `Session.localWorkingDirectory` on
`upstream/master` and the fork's own regression tests. The witnessed run behind the fork's side is in
`12c0b01`: a pane running mosh into p4linux reported `/home/sasha/dev`, no Mac has that path, and
`Process.run()` threw `The file "dev" doesn't exist.` before `/bin/sh` was exec'd, so the park chord
did nothing at all (measured 2026-09-09). The local-row arm is the same throw from a stale path:
`agtermTests/CustomCommandRunnerTests.swift` pins it with a session whose cwd is a plain file, and that
session carries no `remoteHost`, so upstream's guard alone would not catch it.

The layering works and every gate is green. What it costs is a fork-only wrapper sitting on an upstream
function that already means almost the same thing, in `CustomCommandRunner`, the file that collides with
upstream more than any other.

Two ways out, both outside a merge:

1. Propose the widening upstream — drop the `remoteHost != nil` guard from `localWorkingDirectory` and
   let local existence decide for every session. Upstream's own
   `localWorkingDirectoryKeepsAnyPathForALocalSession` pins the current behaviour, so this is a
   behaviour change upstream has to want, not a patch the fork can carry quietly.
2. Drop the fork's widening and accept upstream's narrower guard, deleting the two fork tests that pin
   the local-row arm. Cheapest to maintain, and it gives up a real case.

Not a defect. Nothing is broken today; this is fork code that may not need to exist.
