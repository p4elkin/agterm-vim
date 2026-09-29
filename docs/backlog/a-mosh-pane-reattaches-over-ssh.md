---
worth: later
where: agterm/Ghostty/PaneLead.swift:PaneReattach.launch
added: 2026-09-30
---
# a mosh pane reattaches over ssh

`zmx.attach --transport mosh` builds each pane's command with the chosen transport, but nothing records that
choice on the session. `PaneReattach.launch` rebuilds a remote pane's command from `remotePresentation.binding`
alone and calls `RemoteSession.attachPaneCommand` without `transport:`, so it defaults to `.ssh`.

This predates the 2026-09-30 upstream merge for the lead takeover reattach. Upstream #655 adds a second caller:
the pane command now waits on exit 255 and `tickReconnects` → `PaneLead.reconnect` reattaches it once an
`ssh … true` probe answers.

## What happened

Not reproduced; derived from reading `PaneReattach.launch` and `RemoteSession.attachPaneCommand`.
A pane attached with `--transport mosh --mosh-server /opt/homebrew/bin/mosh-server` to `buildbox`: the far side
takes the lead from another client, then the user presses a key to take it back. The new pane runs
`ssh -tt … buildbox '<quoted attach>'`, not mosh. The same happens when the mosh wrapper exits 255 (perl `die`
on a failed ssh bootstrap) and the reconnect loop fires. The pane works, but silently loses roaming and the
`--mosh-server` path, and `--mosh PATH` is never used again.

Fix shape: carry `RemoteTransport` on the remote binding (or `RemoteReconnectBook` entry) and pass it through
`PaneReattach.launch`. Also decide whether exit 255 means the same thing under mosh as under ssh.
