import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ZmxNewWorkspaceTests {
    private func dispatch(_ request: ControlRequest, _ actions: some ControlActions) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(request)
    }

    @Test func hostedZmxNewCarriesTheWorkspaceInTheOptions() async throws {
        let actions = MockControlActions()
        var args = ControlArgs(host: "p4linux")
        args.workspace = " 5FDA "
        let response = try #require(await dispatch(ControlRequest(cmd: .zmxNew, args: args), actions))

        #expect(response.ok)
        #expect(actions.calls == [.zmxNewRemote(host: "p4linux", options: ControlZmxNewOptions(workspace: "5FDA"), window: nil)])
    }

    @Test(arguments: [nil, "", "  "] as [String?])
    func zmxNewRefusesAWorkspaceWithoutAHost(_ host: String?) async throws {
        let actions = MockControlActions()
        var args = ControlArgs(host: host)
        args.workspace = "active"
        let response = try #require(await dispatch(ControlRequest(cmd: .zmxNew, args: args), actions))

        #expect(response.error == "zmx.new --workspace needs a host")
        #expect(actions.calls.isEmpty)
    }

    @Test func aBlankWorkspaceIsNoWorkspace() async throws {
        let actions = MockControlActions()
        var args = ControlArgs(host: "p4linux")
        args.workspace = "   "
        _ = try #require(await dispatch(ControlRequest(cmd: .zmxNew, args: args), actions))

        #expect(actions.calls == [.zmxNewRemote(host: "p4linux", options: ControlZmxNewOptions(), window: nil)])
    }

    @Test func theFarCommandNeverCarriesTheWorkspace() throws {
        let argv = try RemoteSession.newCommand(host: "p4linux", options: ControlZmxNewOptions(name: "t", workspace: "5FDA"))

        #expect(argv == (try RemoteSession.newCommand(host: "p4linux", options: ControlZmxNewOptions(name: "t"))))
        #expect(!argv.joined(separator: " ").contains("workspace"))
    }
}
