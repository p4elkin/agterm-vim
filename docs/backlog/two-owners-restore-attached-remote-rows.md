---
worth: later
where: agtermCore/Sources/agtermCore/AppStore+AttachedRestore.swift
added: 2026-11-20
---
# Two mechanisms restore attached remote rows

Upstream (#999, #1030) saves a row attached from another host in the window snapshot
(`WorkspaceSnapshot.attached`) and rebuilds it when the store loads, then checks it against its origin
(`awaitsOriginCheck`). The fork restores the same rows from `remote-rows.json` (`RemoteRowBook`), later at launch.

## What happened

Derived from reading the 2026-11-20 upstream merge, not reproduced.
Left alone, both saved a terminal row; the snapshot rebuilt it first, without the fork's transport, so a mosh
row would come back as ssh, and the book then skipped it as present. The merge split ownership (Sasha,
2026-11-20): `AppStore.attachedSnapshots` leaves out every row `RemoteRowBook.Record.covers`, so the book owns
terminal rows and the snapshot keeps only the rows the book cannot record (page rows).

## What is left

- Upstream's origin check (`awaitsOriginCheck`, `ControlServer+AttachedRestore`) now runs only for the
  snapshot's rows; a book row gets the fork's own reconnect path instead.
- Every upstream change to the snapshot path (new fields, restore order, ended rows) must be judged
  against the book at each merge.
- Retiring one side would end that: either carry `transport`, deferred companions and pending names in
  `AttachedOriginSnapshot` and drop the book, or keep the book and file the rest of upstream's restore
  path as unused. See [[attached-remote-page-row-not-restored]] for the page-row gap the book had.

## 2026-11-23 merge: upstream's relaunch state rides the path the fork skips

Upstream #1072/#1082 (saved pane leads, `reclaim`) and #1073 (`followedCompanions`, `companionsBaselined`) are
saved in `WorkspaceSnapshot.attached`. Two fork behaviours meet them, seen in `swift test` on the merge tree:
- `attachedSnapshots` skips every row `RemoteRowBook.Record.covers`. So for a book row, followed companions are
  never saved: `aRowSavedWithoutTheFollowKeysRestoresEmptyAndNotBaselined` and two
  `WindowLibraryFollowCompanionsTests` find no `attached` entry. Derived from reading the guard.
- Every attached row is restored asleep, with no line and no lead. `aRelaunchReclaimsTheLeadOnlyWhereThePaneLedWhenSaved`
  saves the book rows too, and still reads `reclaim == nil` and a nil `initialCommand` at restore time. Not checked:
  whether the wake path carries the saved lead.
