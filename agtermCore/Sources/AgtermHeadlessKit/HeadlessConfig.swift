import agtermCore
import Foundation

/// Where the headless origin keeps its state, its zmx and its socket. Env-overridable so a second instance
/// cannot land on the first one's daemons.
public struct HeadlessConfig: Sendable {
    public let stateDirectory: String
    public let zmxExecutable: String
    /// `LANG` and `LC_*`. Panes inherit them from the server; an overlay program gets the job helper's ssh
    /// login instead, which on Linux has none, so the launch context carries them.
    public let locale: [String: String]
    /// The name a Mac loads an `--html` page under, normally this machine's Tailscale name. Nil refuses `--html`.
    public let pageHost: String?
    /// 0 takes any free port, which only a test wants: the Mac needs a port it can reach through the firewall.
    public let pagePort: UInt16

    public static let defaultPagePort: UInt16 = 19510

    public var zmxDirectory: String { stateDirectory + "/zmx" }
    public var socketPath: String { ControlResolve.socketPath(stateDir: stateDirectory, appSupport: "") }
    public var endpoint: ControlZmxEndpoint { ControlZmxEndpoint(executable: zmxExecutable, socketDirectory: zmxDirectory) }

    public static func fromEnvironment(_ env: [String: String]) -> HeadlessConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return HeadlessConfig(
            stateDirectory: env["AGTERM_HEADLESS_STATE"] ?? home + "/.local/state/agterm-headless",
            zmxExecutable: env["AGTERM_HEADLESS_ZMX"] ?? home + "/.local/opt/agterm-headless/zmx",
            locale: env.filter { $0.key == "LANG" || $0.key.hasPrefix("LC_") },
            pageHost: env["AGTERM_HEADLESS_PAGE_HOST"].flatMap { $0.isEmpty ? nil : $0 },
            pagePort: env["AGTERM_HEADLESS_PAGE_PORT"].flatMap(UInt16.init) ?? defaultPagePort)
    }
}
