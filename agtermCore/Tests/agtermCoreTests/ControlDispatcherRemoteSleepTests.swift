import Foundation
import Testing

@testable import agtermCore

@MainActor
struct ControlDispatcherRemoteSleepTests {
    @Test func theWireNamesDecodeToTheTwoCommands() throws {
        #expect(Command(rawValue: "session.sleep") == .sessionSleep)
        #expect(Command(rawValue: "session.wake") == .sessionWake)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"session.sleep","target":"9f3c"}"#.utf8))
        #expect(decoded == ControlRequest(cmd: .sessionSleep, target: "9f3c"))
    }

    @Test func sleepAndWakeRouteTheTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let slept = await dispatcher.dispatch(ControlRequest(cmd: .sessionSleep, target: "row", args: ControlArgs(window: "win")))
        let woke = await dispatcher.dispatch(ControlRequest(cmd: .sessionWake, target: "9f3c"))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionSleep))

        #expect(slept == ControlResponse(ok: true))
        #expect(woke == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionAsleep(target: "row", window: "win", asleep: true),
            .sessionAsleep(target: "9f3c", window: nil, asleep: false),
            .sessionAsleep(target: nil, window: nil, asleep: true),
        ])
    }

    @Test func theActionsRefusalIsTheAnswer() async {
        let actions = MockControlActions()
        actions.nextSessionAsleepResponse = ControlResponse(ok: false, error: "session.sleep: shown rows stay awake")

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionSleep, target: "row"))

        #expect(response == ControlResponse(ok: false, error: "session.sleep: shown rows stay awake"))
    }
}
