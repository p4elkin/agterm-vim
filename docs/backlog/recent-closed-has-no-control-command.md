---
worth: maybe
where: agtermCore/Sources/agtermCore/WindowLibrary+RecentClosed.swift:reopenRecentClosedReportingWindow
added: 2026-10-13
---
# Recent Closed has no control command

Reopen Closed Item is reachable from the menu only (`AppActions.openRecentClosed`). No protocol command,
dispatcher case or `agtermctl` subcommand lists the recent-closed items or reopens one, so a script cannot
bring a closed session back with its id, split, flag, context and restore pins; it can only recreate one
with `session new` and lose them. The list is also capped at 20 (`RecentClosedStore.init(limit:)`) and
evicts silently.

Surfaced reviewing https://github.com/umputun/agterm/discussions/737, where a snapshot-and-restore kit
recreates sessions for want of this. The shape would be a recent-closed read plus `session reopen <id>`
over the host-free `reopenRecentClosedReportingWindow`, with protocol, dispatcher, CLI, tests,
`site/commands.html` and the bundled skill.

Undecided, which is why this is `maybe`: command naming, what the list read returns, whether reopen
targets a window, and whether the cap grows or becomes a setting.
