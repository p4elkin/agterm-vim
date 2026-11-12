---
worth: now
where: agtermCore/Sources/AgtermHeadlessKit/
added: 2026-11-11
---
# Upstream's agterm-server duplicates the fork's headless origin

Upstream #949 (`b8a96b1b`, merged 2026-11-09) ships `agterm-server`: a Linux host that runs sessions as
detached zmx daemons and shows them in remote windows on a Mac. It builds `agtermCore` and `agtermctl` on
Linux, adds a windowless store (`daemonBackedPanes`, `presentsRemotely`, `CatalogRoot`), a default-deny
`HeadlessCommandPolicy`, session-bound picks, a pooled ssh `controlPath`, and `open_remote_window` /
`detached_sessions` actions.

The fork solved the same problem first, its own way: `AgtermHeadlessKit`, `agterm-headless`,
`ForwardPolicy.kind(of:)` and `HeadlessCatalog`. See [[headless-origin]].

## What happened

Not reproduced; derived from reading the merge of upstream `316b2e24` into `main`.
The merge stopped with 60 conflicted files and about 110 hunks, most of them in the remote and presentation
code both projects grew for the same purpose (`RemoteSession`, `PresentationHub`, `RemotePresentationClient`,
`ControlProjection`, `WindowLibrary`, `MiscCommands`). Two Linux servers, two command policies and two
`agtermctl` default sockets (`~/.local/state/agterm` upstream, `~/.local/state/agterm-headless` here) will
collide at every future merge.

Decided 2026-11-12 (Sasha): keep the fork's model, where Linux rows sit in any Mac window and workspace. The merge
keeps both servers, so their remote code will keep colliding.

Still open, worth asking upstream in a Discussion: attaching agterm-server sessions as rows in ordinary windows,
then `events.read` on agterm-server. Either would let the fork drop its own server. Not yet checked: whether
agterm-server already supports a single-row attach through `zmx present`, outside a remote window. 