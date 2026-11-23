---
worth: yes
where: agtermCore/Sources/agtermCore/AppStore+Transfer.swift
added: 2026-11-23
---
# Window workspace transfer ignores the root workspace

Upstream #1069 (top-level sessions) gives every store a root workspace, stored last (`AppStore+Root.swift`).
The fork-only window transfer (`WindowLibrary.transferWorkspace`, `AppStore.attachWorkspace`,
`workspaceTransferRefusal`, `WindowLibrary+Transfer.resolveWorkspace`) predates it and still treats
`store.workspaces` as named workspaces only.

## What happened

Witnessed in `swift test` on the 2026-11-23 upstream merge tree. `theOnlyWorkspaceMovesAndItsWindowIsDeleted`
builds a source window with one named workspace and moves it with `transferWorkspace(only.id, from:to:)`.
The source keeps upstream's root, so it is no longer empty: `removedSourceWindow` is nil, the window, its store
and its file stay. Seven tests in `WindowLibraryTransferTests` and one in `WindowLibraryAppRecencyTests` fail
the same way (`workspaces.last` is now the root, not the moved workspace; "the only workspace" is never the only one).

Derived from reading, not reproduced:
- `attachWorkspace` appends, so a moved named workspace lands after the root and breaks `namedEndIndex`.
- `workspaceTransferRefusal` does not refuse the root, so `--workspace active` with the root current moves
  the root container and gives the destination a second one.
- `resolveWorkspace` does not accept the `root` keyword.
- The fork-only `paletteNewSessionWorkspaces` (`AppActions+Palette.swift`) still lists `store.workspaces` by
  `name`, so the root shows as an unnamed last row, and the fork-only `ControlServer+Zmx` workspace resolve
  uses raw `ControlResolve` without `root`.

Fix shape: count and insert against named workspaces (`namedWorkspaces`, `namedEndIndex`), refuse the root
through `rootRefusal`, resolve through `resolveWorkspaceTarget`.
