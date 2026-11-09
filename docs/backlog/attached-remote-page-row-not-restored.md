---
worth: later
where: agtermCore/Sources/agtermCore/RemoteRowBook.swift
added: 2026-11-09
---
# an attached remote page row is not restored after a relaunch

The fork restores a row attached from another Mac (`RemoteRowBook`), and the skill and `zmx attach` help say
so: "the row is restored after a relaunch". Upstream #930 (merged 2026-11-09) added page sessions, and
attaching one from another Mac creates a replica page row through `AppStore.addReplicaPageRoot` (a page
companion goes through `addReplicaPageCompanion`). Neither row has a `remotePresentation` binding or a
daemon, and `RemoteRowBook.Record.init?` returns nil without both. So the book never records such a row.

## What happened

Not reproduced; derived from reading `RemoteRowBook.Record.init?` and `AppStore+ReplicaPage.swift`.
On p4linux, `agtermctl session overlay open --page --url http://localhost:3000` makes a page row. On the Mac,
`agtermctl zmx attach p4linux <id>` shows it as a top-level replica page row next to an attached terminal row.
After the Mac app relaunches, the terminal row comes back from `RemoteRowBook` and the page row does not.
The skill sentence says the attached row is restored, with no exception for a page row.

Choose one: record replica page rows in the book (by origin and remote session id, re-attaching through the
page channel), or keep them unrestored and say so next to the fork's sentence in `SKILL.md` and
`ZmxCommands.swift`.
