---
worth: soon
where: agtermCore/Sources/AgtermHeadlessKit/Headless.swift
added: 2026-11-08
---
# a headless origin advertises forwarded link clicks and then drops them

Upstream #923 (`9a6f8e85`) added `link.click` to `PresentationHub.supportedKinds`, and the Mac origin answers it
through `ControlServer.installRemoteLinkClicks`. The headless origin shares the hub, so its hello now lists the
kind too, but its `hub.onPresenterFrame` handler has no `.linkClick` case and falls to `default: break`.

## What happened

Derived from reading during the 2026-11-08 upstream merge, not reproduced. A Mac presents a session attached from
agterm-headless on p4linux and ⌘-clicks `src/main.zig` in it. `RemotePresentationClient.originSupports("link.click")`
is true, so `LinkOpener` forwards the click instead of answering `originTooOld`. The headless hub passes the frame
to `onPresenterFrame`, which ignores it. Nothing opens and no `link.refused` comes back, so the Mac shows no
refusal either.

## What would fix it

Either answer `.linkClick` in `Headless.swift` with a `.linkRefused` (or open the file the headless way), or keep
`linkClickKind` out of the headless hello so the Mac refuses up front. Needs the Linux gate either way.
