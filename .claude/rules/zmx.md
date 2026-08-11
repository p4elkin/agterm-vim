---
paths:
  - "agtermCore/Sources/agtermCore/ZmxSessionKey.swift"
  - "agtermCore/Sources/agtermCore/ZmxSocketBudget.swift"
  - "agtermCore/Sources/agtermCore/ZmxListParser.swift"
  - "agtermCore/Sources/agtermCore/ZmxWrap.swift"
  - "agtermCore/Sources/agtermCore/ZmxLifecycle.swift"
  - "agtermCore/Sources/agtermCore/ZmxReaper.swift"
  - "agtermCore/Sources/agtermCore/ZmxForegroundSelection.swift"
  - "agterm/Ghostty/ZmxClient.swift"
  - "agterm/Ghostty/ZmxForegroundResolver.swift"
---

## Native zmx wrapping (fork only)

This feature is part of an internal fork and is not offered upstream. It moves the zmx wrapping that
was previously driven by a zprofile hook inside agterm itself. Every plain interactive pane is
wrapped with `zmx attach <key>` so the app knows which zmx session owns it, enabling accurate
foreground reporting and correct session cleanup.

### Session key convention

Session keys follow `<session-uuid>-<role>` where role is `left`, `right`, `scratch` or `overlay`.
This differs from upstream's `agterm-<hex12>` scheme. Keeping the existing convention means old
daemons are adopted rather than duplicated, and existing tooling that parses this shape remains
compatible. Keys surface in `zmx list`, the pick list, mosh incantations, and remote scripts.

### Wrap decision

A pane is wrapped when ALL of these hold: it is a left or right pane (not scratch or overlay); its
session is not isolated (no `AGTERM_STATE_DIR`); and it has no pinned command (would run a shell,
not replace it). The wrap produces `zmx attach <key>` through `CommandRestore.shellQuotedLine`.

Scratch, overlay and isolated instances never wrap. A row with a pinned command and `--keep-shell-open`
wraps as `zmx attach <key> <shell> -lc '<command>; exec <shell> -l'`.

### Wrapper form

The wrapper is ALWAYS a bare `zmx attach <key>`, never `zmx attach <key> <command>`.
zmx's own help states that a provided command is used INSTEAD of creating a shell.
Folding a command inside would make that command the zmx session's entire process, not a program
inside its shell. That is exactly the vanishing agent row bug: claude exits, the session ends
because its only process is gone, the client exits and the pane has no process at all.

### Keep-shell-open form

`--keep-shell-open` sets the flag on a row with an initial command and causes that command to run
inside the persistent zmx session's shell. After the command exits, the pane lands at a prompt
inside the same session, instead of exiting.
This differs from `--wait`, which holds the surface with a press-any-key prompt and then closes it.
Both address the same user pain and cannot both apply to one row; the dispatcher rejects the
combination. Store this flag on the session for both tree read-back and wrap decisions.

### Isolated instance bypass

When `AGTERM_STATE_DIR` is set, three things are turned off: wrapping (panes run plain shells),
reaping (the launcher does not kill orphaned sessions), and the zmx close/rename sink
(row closes and renames send no zmx commands). This eliminates the cross-instance danger of an
isolated test run killing the deployed app's detached daemons.

### Lifecycle traps

A closed WINDOW keeps its session ids persisted under `~/Library/Application Support/agterm/windows/`
and does not end any zmx session, because the window reopens with them. A closed window is not
a closed row.
The GUI close path is soft close followed by a grace period, then `hardFinalizePendingSession`
(not `closeSession`). This trap also applies to workspace closes routed through pending cleanup.

### Foreground resolution past the wrapper

When `tree --json` is run, `ForegroundProcess` checks whether a pane's immediate child is `zmx attach`
for an owned key. If so, it reads the zmx process listing and inspects the session leader's foreground
group instead of the wrapper's. This reports the real running program. A wrapper detection is a pure
argv check with no subprocess. The listing is cached for one tree build and run at most once per
tree command, even with many wrapped panes.
