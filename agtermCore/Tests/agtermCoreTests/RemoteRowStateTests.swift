import Foundation
import Testing
@testable import agtermCore

struct RemoteRowStateTests {
    private let endpoint = ControlZmxEndpoint(executable: "/zmx", socketDirectory: "/tmp/z")

    private func binding(origin: Bool = true) -> RemoteBinding {
        RemoteBinding(remoteSessionID: "wanted", daemonsByLocalPane: [:], presentationVersion: 1,
            origin: origin ? RemoteBinding.Origin(host: "p4linux", endpoint: endpoint, sessionName: "work") : nil)
    }

    private func tree(endpoint: ControlZmxEndpoint? = nil, ids: [String] = []) -> ControlResponse {
        let sessions = ids.map {
            ControlRemoteSession(id: $0, name: "work", windowID: "w", windowName: "window", workspaceID: "ws",
                workspaceName: "workspace", cwd: "/tmp", splitAxis: nil, panes: [])
        }
        return ControlResponse(ok: true, result: ControlResult(remote:
            ControlRemoteTree(host: "p4linux", endpoint: endpoint ?? self.endpoint, sessions: sessions)))
    }

    @Test func failedAndMissingTreeRepliesAreDisconnected() {
        #expect(RemoteRowState.classify(tree: ControlResponse(ok: false, error: "ssh failed"), binding: binding()) == .disconnected)
        #expect(RemoteRowState.classify(tree: ControlResponse(ok: true), binding: binding()) == .disconnected)
    }

    @Test(arguments: [ControlZmxEndpoint(executable: "/other/zmx", socketDirectory: "/tmp/z"),
                      ControlZmxEndpoint(executable: "/zmx", socketDirectory: "/other/z")])
    func aDifferentEndpointCannotDeclareTheSessionEnded(other: ControlZmxEndpoint) {
        #expect(RemoteRowState.classify(tree: tree(endpoint: other), binding: binding()) == .disconnected)
        #expect(RemoteRowState.classify(tree: tree(endpoint: other, ids: ["wanted"]), binding: binding()) == .disconnected)
    }

    @Test func aMatchingEndpointWithoutTheSessionMeansEndedOnHost() {
        #expect(RemoteRowState.classify(tree: tree(ids: ["other"]), binding: binding()) == .endedOnHost)
    }

    @Test func aMatchingEndpointListingTheSessionMeansAttached() {
        #expect(RemoteRowState.classify(tree: tree(ids: ["other", "wanted"]), binding: binding()) == .attached)
    }

    @Test func aBindingWithoutAnOriginIsNeverClassified() {
        #expect(RemoteRowState.classify(tree: tree(), binding: binding(origin: false)) == nil)
        #expect(RemoteRowState.classify(tree: ControlResponse(ok: false), binding: binding(origin: false)) == nil)
    }

    @Test func rowNoticesNameTheHostAndGiveTheRequiredRecovery() {
        #expect(RemoteRowState.attached.rowNotice(host: "p4linux") == nil)
        #expect(RemoteRowState.disconnected.rowNotice(host: "p4linux") == "Disconnected from p4linux, retrying")
        #expect(RemoteRowState.endedOnHost.rowNotice(host: "p4linux") == "Ended on p4linux. Close the row to remove it")
    }
}
