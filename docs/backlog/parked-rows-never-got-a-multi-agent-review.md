---
worth: yes
where: branch parked-sessions, docs/plans/completed/20260814-parked-session-state.md and 20260815-hide-parked-rows.md
added: 2026-08-21
---
# the parked-row feature shipped on one reviewer, not a panel

Two phases, eighteen tasks, ~45 files: `Session.parked` with `session.park`, a dimmed sidebar row and
tree read-back, then hiding those rows behind `hideParked` + `parkedRevealedWorkspaceIDs`,
`sidebar.parked`, and a `⏸ N` workspace suffix.

The review it got was **one Opus subagent**, chosen over `revmux` for time. That single pass was worth
it — it found a major defect nothing else had: the sidebar's drag-reorder mixed a DRAWN child index
with a MODEL index, silently reordering the persisted tree while the sidebar redrew identically. The two
index spaces had been identical until parked rows could be hidden, so no existing code reconciled them.
One reviewer finding one bug of that shape is the argument for running the panel, not against it.

What a `revmux` round should look at, beyond a general pass:

- the drag fix itself (`AppStore.modelInsertionIndex`, `visibleSessionLocation`, and the drawn-space
  conversion in `WorkspaceSidebar+DragDrop.swift`) — it was written under time pressure right after the
  finding, and `agtermUITests` has never exercised a drag across a hidden row
- `session.move --direction up|down` and the keyboard reorder, which walk `workspace.sessions` directly:
  a step across a hidden parked row moves the model with nothing visible changing. Known, unfixed,
  lower impact than the drag because it does not persist a surprise
- whether any path still selects or reveals a row the sidebar does not draw. The reviewer traced every
  consumer of `navigableSessions` and found none, but `attentionSessions` deliberately spans the whole
  tree and is only saved by the selected-row exemption
- the app-side `setSidebarParked` arm in `ControlServer+AppCommands.swift`, which has no hosted test, so
  "an id naming no workspace errors" rests on `resolveWorkspace`'s general behaviour

Two things the single reviewer flagged and we accepted rather than fixed:

- `AppStore.swift` and `ControlDispatcher.swift` sit at **exactly 1000 lines**, the lint cap. They were at
  991 and 986 before this branch. The next line added to either fails `make lint`, and `origin/main` keeps
  touching both.
- in the flat flagged view a hidden parked row vanishes with no counter — the `⏸ N` reassurance is a
  workspace row, and that view has none. "Nothing disappears without trace" holds in tree mode only.
