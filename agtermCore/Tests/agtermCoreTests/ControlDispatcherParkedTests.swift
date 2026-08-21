import Foundation
import Testing

@testable import agtermCore

/// `session.park`'s dispatch. Its own file because `ControlDispatcherTests.swift` was already 1987 lines
/// on `origin/main`, thirteen under the 2000-line test cap.
@MainActor
struct ControlDispatcherParkedTests {
@Test func sessionParkRoutesTheParsedMode() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let parked = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionPark,
            target: "session",
            args: ControlArgs(mode: "on", window: "win")
        ))
        let unparked = await dispatcher.dispatch(ControlRequest(cmd: .sessionPark, target: "9f3c",
                                                                args: ControlArgs(mode: "off")))

        #expect(parked == ControlResponse(ok: true))
        #expect(unparked == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionPark(target: "session", window: "win", .on),
            .sessionPark(target: "9f3c", window: nil, .off)
        ])
    }

    @Test func sessionParkDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionPark))

        #expect(actions.calls == [.sessionPark(target: nil, window: nil, .toggle)])
    }

    @Test func sessionParkRejectsUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionPark, target: "active",
                                                                args: ControlArgs(mode: "clear")))

        #expect(response == ControlResponse(ok: false, error: "invalid park mode: clear"))
        #expect(actions.calls.isEmpty)
    }
}
