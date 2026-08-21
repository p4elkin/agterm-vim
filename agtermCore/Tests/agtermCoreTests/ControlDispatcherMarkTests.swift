import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherMarkTests {
    @Test func sessionMarkRoutesTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionMarkResponse = ControlResponse(ok: true, result: ControlResult(count: 3))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMark, target: "session", args: ControlArgs(window: "win")))

        #expect(response == ControlResponse(ok: true, result: ControlResult(count: 3)))
        #expect(actions.calls == [.sessionMark(target: "session", window: "win")])
    }

    @Test func sessionMarkAdvancesTheCounterPerSessionAndReadsBackAsTurn() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let marked = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        let other = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/b"))
        actions.markStore = store

        let first = await dispatcher.dispatch(ControlRequest(cmd: .sessionMark, target: marked.id.uuidString))
        let second = await dispatcher.dispatch(ControlRequest(cmd: .sessionMark, target: marked.id.uuidString))

        #expect(first?.result?.count == 1)
        #expect(second?.result?.count == 2)
        let sessions = store.controlTree().workspaces[0].sessions
        #expect(sessions.first { $0.id == marked.id.uuidString }?.turn == 2)
        // a never-marked session omits the field, like `unseen` at zero
        #expect(sessions.first { $0.id == other.id.uuidString }?.turn == nil)
    }

    @Test func sessionMarkUnknownTargetErrorsWithoutAdvancing() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        actions.markStore = store

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionMark, target: UUID().uuidString))

        #expect(response?.ok == false)
        #expect(session.turnCounter == 0)
    }
}
