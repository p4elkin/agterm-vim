import Foundation
import Testing
@testable import agtermCore

/// A runner whose every master answers, so a lease's `ready` never fails.
struct AnsweringRunner: RemoteCommandRunner {
    func run(_ argv: [String], deadline: TimeInterval) async -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}

@MainActor
struct SshHostPoolsTests {
    private func pools() -> SshHostPools {
        SshHostPools(root: "/tmp/agterm-ssh-test", owner: "/state-\(UUID().uuidString)", runner: AnsweringRunner())
    }

    @Test func eachHostGetsOnePool() {
        let pools = pools()

        let first = pools.pool(for: "box")

        #expect(pools.pool(for: "box") === first)
        #expect(pools.pool(for: "other") !== first)
        #expect(pools.pool(for: "other").host == "other")
    }

    @Test func twoOwnersNeverShareAConnection() {
        let one = SshHostPools(root: "/tmp/agterm-ssh-test", owner: "/state-a", runner: AnsweringRunner())
        let two = SshHostPools(root: "/tmp/agterm-ssh-test", owner: "/state-b", runner: AnsweringRunner())

        #expect(one.lease(host: "box", transport: .ssh, user: "pane:a") != two.lease(host: "box", transport: .ssh, user: "pane:a"))
    }

    @Test func aMoshRowGetsNoPath() {
        let pools = pools()

        #expect(pools.lease(host: "box", transport: .mosh(server: nil, client: nil), user: "pane:a") == nil)
        #expect(pools.pool(for: "box").load.isEmpty)
    }

    @Test func nineLeasesOnOneHostFillOneConnectionAndOpenASecond() {
        let pools = pools()

        let paths = (0..<9).compactMap { pools.lease(host: "box", transport: .ssh, user: "pane:\($0)") }

        #expect(paths.count == 9)
        #expect(Set(paths.prefix(8)).count == 1)
        #expect(paths[8] != paths[0])
        #expect(pools.pool(for: "box").load == [8, 1])
    }

    @Test func retainReleasesOnlyTheNamedKindInEveryPool() {
        let pools = pools()
        _ = pools.lease(host: "box", transport: .ssh, user: "pane:a")
        _ = pools.lease(host: "box", transport: .ssh, user: "present:a")
        _ = pools.lease(host: "other", transport: .ssh, user: "pane:b")

        pools.retain(["pane:a"], prefix: "pane:")

        #expect(pools.pool(for: "box").load == [2])
        #expect(pools.pool(for: "other").load == [0])
    }
}
