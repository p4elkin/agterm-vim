import agtermCore
import Foundation

/// Where the headless origin keeps its state, its zmx and its socket. Env-overridable so a second instance
/// cannot land on the first one's daemons.
public struct HeadlessConfig: Sendable {
    public let stateDirectory: String
    public let zmxExecutable: String

    public var zmxDirectory: String { stateDirectory + "/zmx" }
    public var socketPath: String { ControlResolve.socketPath(stateDir: stateDirectory, appSupport: "") }
    public var endpoint: ControlZmxEndpoint { ControlZmxEndpoint(executable: zmxExecutable, socketDirectory: zmxDirectory) }

    public static func fromEnvironment(_ env: [String: String]) -> HeadlessConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return HeadlessConfig(
            stateDirectory: env["AGTERM_HEADLESS_STATE"] ?? home + "/.local/state/agterm-headless",
            zmxExecutable: env["AGTERM_HEADLESS_ZMX"] ?? home + "/.local/opt/agterm-headless/zmx")
    }
}
