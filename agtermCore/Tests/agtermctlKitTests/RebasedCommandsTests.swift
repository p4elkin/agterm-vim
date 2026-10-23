import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct RebasedCommandsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func node(daysAgo: Double, bytes: Int? = 101_000_000, inUse: Bool = false,
                      error: String? = nil) -> ControlRebasedMirrorNode {
        ControlRebasedMirrorNode(host: "p4linux", source: "p4linux:/home/s/jackrabbit",
                                 directory: "/Users/s/mirrors/p4linux/ab12/jackrabbit",
                                 lastOpened: now.timeIntervalSince1970 - daysAgo * 86400 - 60,
                                 bytes: bytes, inUse: inUse, error: error)
    }

    @Test func listParsesFromTheRoot() throws {
        #expect(try request(["rebased", "mirror", "list"]) == ControlRequest(cmd: .rebasedMirrorList))
    }

    @Test func pruneWithoutFlagsLeavesTheAgeToTheSetting() throws {
        let request = try request(["rebased", "mirror", "prune"])
        #expect(request == ControlRequest(cmd: .rebasedMirrorPrune, args: ControlArgs()))
        #expect(request.args?.olderThanDays == nil)
        #expect(request.args?.dryRun == nil)
    }

    @Test func pruneCarriesOlderThanAndDryRun() throws {
        let request = try request(["rebased", "mirror", "prune", "--older-than", "30", "--dry-run"])
        #expect(request == ControlRequest(cmd: .rebasedMirrorPrune, args: ControlArgs(olderThanDays: 30, dryRun: true)))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test(arguments: ["--older-than=0", "--older-than=-3"])
    func olderThanBelowOneIsRefusedInTheDispatchersWords(_ flag: String) {
        do {
            _ = try Agtermctl.parseAsRoot(["rebased", "mirror", "prune", flag])
            Issue.record("expected \(flag) to be refused")
        } catch {
            #expect(Agtermctl.message(for: error) == "rebased.mirror.prune --older-than must be 1 or more")
        }
    }

    @Test func listRendersOneLinePerMirrorWithInUseBeforeTheDirectory() {
        let mirrors = ControlRebasedMirrors(mirrors: [node(daysAgo: 20), node(daysAgo: 1, bytes: nil, inUse: true)])
        #expect(SocketClient.formatRebasedMirrors(mirrors, now: now) == """
        p4linux  p4linux:/home/s/jackrabbit  20 days  101 MB  /Users/s/mirrors/p4linux/ab12/jackrabbit
        p4linux  p4linux:/home/s/jackrabbit  1 day  -  in use  /Users/s/mirrors/p4linux/ab12/jackrabbit
        """)
    }

    @Test func emptyListSaysNoMirrors() {
        let response = ControlResponse(ok: true, result: ControlResult(rebasedMirrors: ControlRebasedMirrors(mirrors: [])))
        #expect(SocketClient.formatResponse(response) == "no mirrors")
    }

    @Test func pruneMarksRemovedAndBothKindsOfKept() {
        let report = ControlRebasedMirrors(removed: [node(daysAgo: 20)],
                                           kept: [node(daysAgo: 30, inUse: true),
                                                  node(daysAgo: 40, bytes: 1_500_000_000, error: "permission denied")],
                                           dryRun: false, olderThanDays: 14)
        #expect(SocketClient.formatRebasedMirrors(report, now: now) == """
        removed  p4linux  p4linux:/home/s/jackrabbit  20 days  101 MB  /Users/s/mirrors/p4linux/ab12/jackrabbit
        kept: in use  p4linux  p4linux:/home/s/jackrabbit  30 days  101 MB  /Users/s/mirrors/p4linux/ab12/jackrabbit
        kept: permission denied  p4linux  p4linux:/home/s/jackrabbit  40 days  1.5 GB  /Users/s/mirrors/p4linux/ab12/jackrabbit
        """)
    }

    @Test func dryRunSaysWouldRemove() {
        let report = ControlRebasedMirrors(removed: [node(daysAgo: 20, bytes: 4_200)], kept: [],
                                           dryRun: true, olderThanDays: 14)
        #expect(SocketClient.formatRebasedMirrors(report, now: now)
                == "would remove  p4linux  p4linux:/home/s/jackrabbit  20 days  4.2 KB  /Users/s/mirrors/p4linux/ab12/jackrabbit")
    }

    @Test func emptyPruneNamesTheAgeItUsed() {
        let report = ControlRebasedMirrors(removed: [], kept: [], dryRun: false, olderThanDays: 14)
        let response = ControlResponse(ok: true, result: ControlResult(rebasedMirrors: report))
        #expect(SocketClient.formatResponse(response) == "no mirrors older than 14 days")
    }
}
