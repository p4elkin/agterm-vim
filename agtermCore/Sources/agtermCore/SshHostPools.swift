import Foundation

/// SshHostPools holds one `SshConnectionPool` per host for the rows that are not a remote window's, so their pane
/// attaches, presentation streams, overlay jobs and reconnect probes share masters of at most eight channels each.
/// A pool is never closed: an idle master ends on its own `ControlPersist=60`.
@MainActor
public final class SshHostPools {
    private let root: String
    private let owner: String
    private let runner: SshConnectionPool.Runner
    private(set) var pools: [String: SshConnectionPool] = [:]

    /// `owner` keys the masters, so two state directories never share one.
    public init(root: String, owner: String, runner: any RemoteCommandRunner) {
        self.root = root
        self.owner = owner
        self.runner = { argv in await runner.run(argv, deadline: 15).status }
    }

    public func pool(for host: String) -> SshConnectionPool {
        if let pool = pools[host] { return pool }
        let pool = SshConnectionPool(host: host, root: root, key: "\(owner)|host|\(host)", runner: runner)
        pools[host] = pool
        return pool
    }

    /// lease is `user`'s control path on `host`'s pool.
    public func lease(host: String, user: String) -> String {
        pool(for: host).lease(user)
    }

    /// retain keeps, in every pool, the users of kind `prefix` that are in `users` and releases the rest of that kind.
    public func retain(_ users: Set<String>, prefix: String) {
        for pool in pools.values { pool.retain(users, prefix: prefix) }
    }
}
