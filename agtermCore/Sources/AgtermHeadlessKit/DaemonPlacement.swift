import Foundation

/// Where a daemon the server creates lives: in a transient systemd scope of its own, outside the service's cgroup,
/// so the unit's memory and CPU accounting describe the server and not every terminal it ever opened; or, with no
/// user manager to ask, wherever zmx puts it.
/// A copy of upstream's `AgtermServerKit.ServerPlacement`, kept here so the headless kit imports no second server.
public enum DaemonPlacement: Equatable, Sendable {
    case direct
    case systemdScope(systemdRun: String)

    /// detect picks a scope when the user manager's private socket exists and `systemd-run` is on PATH.
    public static func detect(environment: [String: String], fileManager: FileManager = .default) -> DaemonPlacement {
        guard let runtime = environment["XDG_RUNTIME_DIR"],
              fileManager.fileExists(atPath: (runtime as NSString).appendingPathComponent("systemd/private")) else {
            return .direct
        }
        let path = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        guard let run = path.map({ ($0 as NSString).appendingPathComponent("systemd-run") })
            .first(where: fileManager.isExecutableFile(atPath:)) else { return .direct }
        return .systemdScope(systemdRun: run)
    }

    /// prefix is what runs the zmx create. The random suffix keeps a respawned pane, which reuses its daemon
    /// name, off a scope not yet collected.
    public func prefix(for name: String) -> [String] {
        switch self {
        case .direct: []
        case .systemdScope(let run):
            [run, "--user", "--scope", "--quiet", "--collect",
             "--unit=\(name)-\(UUID().uuidString.prefix(8).lowercased()).scope", "--"]
        }
    }
}
