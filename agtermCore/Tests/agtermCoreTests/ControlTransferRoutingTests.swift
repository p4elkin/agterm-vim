import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlTransferRoutingTests {
    private func dispatch(_ request: ControlRequest, _ actions: some ControlActions) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(request)
    }

    @Test func toWindowAndWindowNameRoundTripThroughJSON() throws {
        let request = ControlRequest(cmd: .workspaceMove, target: "w1", args: ControlArgs(toWindow: "new", windowName: "build"))
        let data = try JSONEncoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""toWindow":"new""#))
        #expect(json.contains(#""windowName":"build""#))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
    }

    @Test func workspaceMoveWithToWindowAwaitsTheTransfer() async throws {
        let actions = MockControlActions()

        let response = try #require(await dispatch(
            ControlRequest(cmd: .workspaceMove, target: "w1",
                           args: ControlArgs(window: "src", toWindow: "new", windowName: "build")), actions))

        #expect(response.ok)
        #expect(actions.calls == [.workspaceTransfer(target: "w1", window: "src", toWindow: "new", windowName: "build")])
    }

    @Test func workspaceMoveRefusesToAndToWindowTogether() async throws {
        let actions = MockControlActions()

        let response = try #require(await dispatch(
            ControlRequest(cmd: .workspaceMove, target: "w1", args: ControlArgs(to: "up", toWindow: "new")), actions))

        #expect(response.error == "--to and --to-window are exclusive")
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionMoveWithToWindowAwaitsTheTransferWithTheBatch() async throws {
        let actions = MockControlActions()

        let response = try #require(await dispatch(
            ControlRequest(cmd: .sessionMove,
                           args: ControlArgs(targets: ["s1", "s2"], workspace: "w9", window: "src", toWindow: "work")), actions))

        #expect(response.ok)
        #expect(actions.calls == [.sessionTransfer(targets: ["s1", "s2"], window: "src", toWindow: "work",
                                                   workspace: "w9", workspaceName: nil, windowName: nil)])
    }

    @Test func sessionMoveWithToWindowSendsASingleTargetAsABatchOfOne() async throws {
        let actions = MockControlActions()

        _ = await dispatch(ControlRequest(cmd: .sessionMove, target: "s1",
                                          args: ControlArgs(workspaceName: "logs", toWindow: "new", windowName: "ops")), actions)

        #expect(actions.calls == [.sessionTransfer(targets: ["s1"], window: nil, toWindow: "new",
                                                   workspace: nil, workspaceName: "logs", windowName: "ops")])
    }

    @Test(arguments: [ControlArgs(to: "up", toWindow: "new"), ControlArgs(toWindow: "new", after: "s2"),
                      ControlArgs(toWindow: "new", before: "s2")])
    func sessionMoveRefusesToWindowWithAPlacement(_ args: ControlArgs) async throws {
        let actions = MockControlActions()

        let response = try #require(await dispatch(ControlRequest(cmd: .sessionMove, target: "s1", args: args), actions))

        #expect(response.error == "--to-window cannot be combined with --to, --after or --before")
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionMoveRefusesAWorkspaceWithAWorkspaceName() async throws {
        let actions = MockControlActions()

        let response = try #require(await dispatch(
            ControlRequest(cmd: .sessionMove, target: "s1",
                           args: ControlArgs(workspace: "w9", workspaceName: "logs", toWindow: "new")), actions))

        #expect(response.error == "use either --workspace or --workspace-name, not both")
        #expect(actions.calls.isEmpty)
    }

    @Test func movesWithoutToWindowRouteAsBefore() async {
        let actions = MockControlActions()

        _ = await dispatch(ControlRequest(cmd: .workspaceMove, target: "w1", args: ControlArgs(to: "top")), actions)
        _ = await dispatch(ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(workspace: "w2")), actions)
        _ = await dispatch(ControlRequest(cmd: .sessionMove, args: ControlArgs(targets: ["s1", "s2"], workspace: "w2")), actions)

        #expect(actions.calls == [
            .workspaceMove(target: "w1", window: nil, .top),
            .sessionMove(target: "s1", window: nil, .workspace("w2")),
            .sessionMoveBatch(targets: ["s1", "s2"], window: nil, .workspace("w2")),
        ])
    }

    @Test func aHostWithoutTransfersAnswersUnsupported() async throws {
        let actions = DefaultsOnlyActions()

        let workspace = try #require(await dispatch(
            ControlRequest(cmd: .workspaceMove, target: "w1", args: ControlArgs(toWindow: "new")), actions))
        let session = try #require(await dispatch(
            ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(toWindow: "new")), actions))

        #expect(workspace.error == ControlActionsUnsupported.message("workspace.move --to-window"))
        #expect(session.error == ControlActionsUnsupported.message("session.move --to-window"))
        #expect(actions.calls.isEmpty)
    }
}
