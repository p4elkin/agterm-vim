import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherRebasedMirrorTests {
    private func dispatch(_ request: ControlRequest, _ actions: some ControlActions) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(request)
    }

    @Test func listRoutesWithNoArgumentsToParse() async throws {
        let actions = MockControlActions()
        let response = try #require(await dispatch(ControlRequest(cmd: .rebasedMirrorList), actions))
        #expect(response.ok)
        #expect(actions.calls == [.rebasedMirrorList])
    }

    @Test func pruneWithNoArgumentsLeavesTheAgeToTheHost() async throws {
        let actions = MockControlActions()
        let response = try #require(await dispatch(ControlRequest(cmd: .rebasedMirrorPrune), actions))
        #expect(response.ok)
        #expect(actions.calls == [.rebasedMirrorPrune(olderThanDays: nil, dryRun: false)])
    }

    @Test func prunePassesTheAgeAndDryRunThrough() async throws {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .rebasedMirrorPrune, args: ControlArgs(olderThanDays: 3, dryRun: true))
        let response = try #require(await dispatch(request, actions))
        #expect(response.ok)
        #expect(actions.calls == [.rebasedMirrorPrune(olderThanDays: 3, dryRun: true)])
    }

    @Test(arguments: [0, -1])
    func pruneRefusesAnAgeBelowOne(days: Int) async throws {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .rebasedMirrorPrune, args: ControlArgs(olderThanDays: days))
        let response = try #require(await dispatch(request, actions))
        #expect(!response.ok)
        #expect(response.error == "rebased.mirror.prune --older-than must be 1 or more")
        #expect(actions.calls.isEmpty)
    }

    @Test func aHostWithoutTheCommandsRefusesThemByName() async throws {
        let actions = DefaultsOnlyActions()
        let list = try #require(await dispatch(ControlRequest(cmd: .rebasedMirrorList), actions))
        let prune = try #require(await dispatch(ControlRequest(cmd: .rebasedMirrorPrune), actions))
        #expect(list.error == ControlActionsUnsupported.message("rebased.mirror.list"))
        #expect(prune.error == ControlActionsUnsupported.message("rebased.mirror.prune"))
    }

    @Test func thePayloadSurvivesAJSONRoundTrip() throws {
        let removed = ControlRebasedMirrorNode(host: "p4linux", source: "p4linux:/home/s/jackrabbit",
                                               directory: "/m/p4linux/1a2b/jackrabbit", lastOpened: 1_791_000_000,
                                               bytes: 101_000_000, inUse: false,
                                               ideData: ["/s/system/projects/jackrabbit.1a2b"])
        let kept = ControlRebasedMirrorNode(host: "p4linux", directory: "/m/p4linux/3c4d", lastOpened: 1_790_000_000,
                                            inUse: false, error: "permission denied",
                                            sync: ControlRebasedMirrorSync(state: "unknown", error: "daemon gone"))
        let prune = ControlResult(rebasedMirrors: ControlRebasedMirrors(removed: [removed], kept: [kept],
                                                                        dryRun: true, olderThanDays: 14))
        let list = ControlResult(rebasedMirrors: ControlRebasedMirrors(mirrors: [removed, kept]))

        for result in [prune, list] {
            let decoded = try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result))
            #expect(decoded == result)
        }
    }

    @Test func aPayloadWithoutSyncStillDecodes() throws {
        let json = #"{"host": "h", "directory": "/d", "lastOpened": 1, "inUse": false}"#
        let node = try JSONDecoder().decode(ControlRebasedMirrorNode.self, from: Data(json.utf8))
        #expect(node.sync == nil)
        let synced = #"{"host": "h", "directory": "/d", "lastOpened": 1, "inUse": false, "sync": {"state": "watching"}}"#
        #expect(try JSONDecoder().decode(ControlRebasedMirrorNode.self, from: Data(synced.utf8)).sync == .init(state: "watching"))
    }

    @Test func aReportCarriesEachMirrorsSyncIntoItsNode() {
        let record = RebasedMirrorRecord(host: "h", source: nil, clone: URL(fileURLWithPath: "/m/h/1/r"),
                                         hashDirectory: URL(fileURLWithPath: "/m/h/1"), lastOpened: Date(timeIntervalSince1970: 1),
                                         bytes: nil, inUse: false)
        let report = RebasedMirrorCleanup.Report(removed: [.init(mirror: record, ideData: [], error: nil)],
                                                 kept: [.init(mirror: record, ideData: [], error: "x")], dryRun: true, olderThanDays: 3)
            .withSync { _ in ControlRebasedMirrorSync(state: "paused") }
        let nodes = ControlRebasedMirrors(report: report)
        #expect(nodes.removed?.map(\.sync) == [.init(state: "paused")])
        #expect(nodes.kept?.map(\.sync) == [.init(state: "paused")])
        #expect(ControlRebasedMirrors(mirrors: [record]).mirrors?.first?.sync == nil)
    }

    @Test func absentFieldsStayOffTheWire() throws {
        let node = ControlRebasedMirrorNode(host: "h", directory: "/d", lastOpened: 1, inUse: true)
        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(ControlRebasedMirrors(mirrors: [node]))) as? [String: Any])
        #expect(Set(json.keys) == ["mirrors"])
        let first = try #require((json["mirrors"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["host", "directory", "lastOpened", "inUse"])
    }

    @Test(arguments: [Command.rebasedMirrorList, .rebasedMirrorPrune])
    func commandsKeepTheirWireNames(command: Command) throws {
        let decoded = try JSONDecoder().decode(ControlRequest.self,
                                               from: JSONEncoder().encode(ControlRequest(cmd: command)))
        #expect(decoded.cmd == command)
        #expect(command.rawValue.hasPrefix("rebased.mirror."))
    }
}
