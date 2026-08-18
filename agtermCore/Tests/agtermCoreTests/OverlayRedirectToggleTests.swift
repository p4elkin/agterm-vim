import Foundation
import Testing
@testable import agtermCore

// The `overlay_redirect_toggle` built-in and its `overlay-redirect.toggle` control command: the raw-value
// round trip, the keyless keymap shape, and on/off/toggle resolving through `ControlToggleMode.parse` via
// the dispatcher. That a bound chord really fires needs `CustomCommandRunner`, which lives in the AppKit
// target: `agtermTests/NormalModeKeyRoutingTests
// .testABareMapToTheKeylessOverlayRedirectToggleFiresThroughTheRunner` is that regression test.
@MainActor
struct OverlayRedirectToggleTests {
    // MARK: - raw value / keymap round trip

    @Test func rawValueRoundTrips() {
        #expect(BuiltinAction(rawValue: "overlay_redirect_toggle") == .overlayRedirectToggle)
        #expect(BuiltinAction.overlayRedirectToggle.rawValue == "overlay_redirect_toggle")
    }

    @Test func isKeylessLikeNormalModeSoItNeedsAnExplicitMapToBeReachable() {
        #expect(BuiltinAction.overlayRedirectToggle.defaultChord == nil)
        let (keymap, diagnostics) = parseKeymap("map ctrl+space overlay_redirect_toggle")
        #expect(diagnostics.isEmpty)
        let chord = Chord(mods: [.control], key: "space")
        // a single-chord `map` line to a KEYLESS action becomes a builtinOverride (a would-be menu
        // equivalent), never a `builtinSequences` entry — only a leader (2+ chords) lands there. This is
        // exactly why `CustomCommandRunner.rebuild()` needs its own merge step for a keyless action: the
        // sequence form is the monitor's only path, and this one arrived as a single chord.
        #expect(keymap.builtinOverrides == [.overlayRedirectToggle: chord])
        #expect(keymap.builtinSequences[.overlayRedirectToggle] == nil)
        #expect(keymap.equivalent(for: .overlayRedirectToggle) == chord)
    }

    // MARK: - overlay-redirect.toggle control command

    @Test func onOffToggleAllResolveThroughControlToggleModeParse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .overlayRedirectToggle, args: ControlArgs(mode: "on")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .overlayRedirectToggle, args: ControlArgs(mode: "off")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .overlayRedirectToggle, args: ControlArgs(mode: "toggle")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .overlayRedirectToggle))

        #expect(actions.calls == [
            .overlayRedirectToggle(.on),
            .overlayRedirectToggle(.off),
            .overlayRedirectToggle(.toggle),
            .overlayRedirectToggle(.toggle),
        ])
    }

    @Test func anUnknownModeIsRejectedWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .overlayRedirectToggle, args: ControlArgs(mode: "sideways")))

        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func theCommandCaseRoundTripsOnTheWire() throws {
        let encoded = try JSONEncoder().encode(Command.overlayRedirectToggle)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text == "\"overlay-redirect.toggle\"")
        let decoded = try JSONDecoder().decode(Command.self, from: encoded)
        #expect(decoded == .overlayRedirectToggle)
    }
}
