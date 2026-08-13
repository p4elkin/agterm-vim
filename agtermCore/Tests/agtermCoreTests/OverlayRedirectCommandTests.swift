import Foundation
import Testing
@testable import agtermCore

// `session.pairing` (mirrors/viewer set + clear) and the `resolved` two-phase field on
// `session.overlay.open`. Dispatcher-level: parsing and validation, not the live `AppStore` mutation,
// which `ControlServerOverlayRedirectTests` covers in the app target.
@MainActor
struct OverlayRedirectCommandTests {
    @Test func mirrorsModeParsesHostAndSessionIntoASetMirrorsUpdate() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayPairingResponse = ControlResponse(ok: true, result: ControlResult(id: "s1"))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1",
            args: ControlArgs(name: "remoteSession", mode: "mirrors", host: "p4studio.local")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "s1")))
        #expect(actions.calls == [
            .overlayPairing(target: "s1", window: nil,
                            .setMirrors(OverlayMirrorSource(host: "p4studio.local", session: "remoteSession")))
        ])
    }

    // The mirror job sends the workstation's real directory with every pass. Without it the CLI falls back to
    // its own process directory, which on a mirrored row is `$HOME` — a path that exists on both machines.
    @Test func mirrorsModeCarriesTheCwdWhenTheMirrorJobSendsOne() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1",
            args: ControlArgs(name: "remoteSession", cwd: "/w/agterm", mode: "mirrors", host: "p4studio.local")
        ))

        #expect(actions.calls == [
            .overlayPairing(target: "s1", window: nil,
                            .setMirrors(OverlayMirrorSource(host: "p4studio.local", session: "remoteSession",
                                                            cwd: "/w/agterm")))
        ])
    }

    @Test func aWhitespaceOnlyCwdIsStoredAsNoCwdRatherThanAnUnusablePath() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1",
            args: ControlArgs(name: "remoteSession", cwd: "  ", mode: "mirrors", host: "p4studio.local")
        ))

        #expect(actions.calls == [
            .overlayPairing(target: "s1", window: nil,
                            .setMirrors(OverlayMirrorSource(host: "p4studio.local", session: "remoteSession")))
        ])
    }

    // The viewer direction has no use for a cwd: the program runs back on the machine the command came from,
    // where the caller's own directory is already the right one.
    @Test func viewerModeIgnoresACwdThatRodeAlong() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1",
            args: ControlArgs(name: "r7", cwd: "/w/agterm", mode: "viewer", host: "p4air.local")
        ))

        #expect(actions.calls == [.overlayPairing(target: "s1", window: nil,
                                                  .setViewer(host: "p4air.local", row: "r7"))])
    }

    @Test func viewerModeParsesHostAndRowIntoASetViewerUpdate() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(name: "r7", mode: "viewer", host: "p4air.local")
        ))

        #expect(actions.calls == [
            .overlayPairing(target: "s1", window: nil, .setViewer(host: "p4air.local", row: "r7"))
        ])
    }

    @Test func aMissingHostIsRejectedForEitherMode() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let mirrors = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(name: "remoteSession", mode: "mirrors")
        ))
        let viewer = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(name: "r7", mode: "viewer")
        ))

        #expect(mirrors?.ok == false)
        #expect(viewer?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func anEmptyHostClearsTheFieldNamedByModeAndIgnoresName() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(mode: "mirrors", host: "")
        ))
        _ = await dispatcher.dispatch(ControlRequest(
            // `name` present but ignored: an empty host always clears, whatever else rode along.
            cmd: .sessionPairing, target: "s1", args: ControlArgs(name: "r7", mode: "viewer", host: "")
        ))

        #expect(actions.calls == [
            .overlayPairing(target: "s1", window: nil, .clearMirrors),
            .overlayPairing(target: "s1", window: nil, .clearViewer)
        ])
    }

    @Test func aNonEmptyHostWithNoNameIsRejected() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(mode: "mirrors", host: "p4studio.local")
        ))

        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func anInvalidModeIsRejected() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(mode: "bogus", host: "p4studio.local")
        ))

        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func theWindowSelectorRidesAlongToTheHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1",
            args: ControlArgs(name: "remoteSession", mode: "mirrors", host: "p4studio.local", window: "win1")
        ))

        #expect(actions.calls == [
            .overlayPairing(target: "s1", window: "win1",
                            .setMirrors(OverlayMirrorSource(host: "p4studio.local", session: "remoteSession")))
        ])
    }

    // MARK: - session.overlay.open's `resolved` field

    @Test func resolvedDefaultsToFalseWhenAbsent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "s1", args: ControlArgs(command: "revdiff")
        ))

        guard case .overlayOpen(_, _, let options) = actions.calls.first else {
            Issue.record("expected an overlayOpen call")
            return
        }
        #expect(options.resolved == false)
    }

    /// `agtermctl`'s two-phase re-send sets `resolved`; the dispatcher forwards it opaquely, so the app
    /// layer alone decides what to skip on it.
    @Test func aRequestCarryingResolvedForwardsItUntouchedRatherThanActingOnItHere() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionOverlayOpen, target: "s1", args: ControlArgs(command: "revdiff", resolved: true)
        ))

        guard case .overlayOpen(_, _, let options) = actions.calls.first else {
            Issue.record("expected an overlayOpen call")
            return
        }
        #expect(options.resolved == true)
        #expect(options.command == "revdiff")
    }

    /// `host` is trimmed like `name`: a whitespace-only host would be stored as a pairing that could only
    /// ever fail later, at ssh time, against a machine nobody is watching. Trimmed to nothing, it clears.
    @Test func aWhitespaceOnlyHostClearsRatherThanStoringAnUnusablePairing() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(name: "r7", mode: "viewer", host: "   ")))
        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(name: "abc", mode: "mirrors", host: " \t")))

        #expect(actions.calls == [.overlayPairing(target: "s1", window: nil, .clearViewer),
                                  .overlayPairing(target: "s1", window: nil, .clearMirrors)])
    }

    @Test func aPaddedHostIsStoredTrimmed() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPairing, target: "s1", args: ControlArgs(name: "r7", mode: "viewer", host: " air ")))

        #expect(actions.calls == [.overlayPairing(target: "s1", window: nil,
                                                  .setViewer(host: "air", row: "r7"))])
    }
}
