import Foundation
import OSLog
import agtermCore

private let onCloseLogger = Logger(subsystem: "com.umputun.agterm", category: "RebasedOnClose")

enum RebasedOnCloseRunner {
    struct Launch: Equatable {
        let argv: [String]
        let cwd: String?
        let environment: [String: String]
    }

    /// A host callback runs over ssh with this app's environment (`HOME`, `SSH_AUTH_SOCK`); its cwd is on the host.
    static func launch(for captured: RebasedOnClose) -> Launch {
        if let remote = captured.remoteArgv {
            return Launch(argv: remote, cwd: nil, environment: ProcessInfo.processInfo.environment)
        }
        return Launch(argv: ["/bin/sh", "-c", captured.command], cwd: captured.cwd, environment: captured.environment)
    }

    @discardableResult
    static func run(_ captured: RebasedOnClose, spawn: (Launch) throws -> Void = spawnProcess,
                    logFailure: (String) -> Void = { onCloseLogger.error("\($0, privacy: .public)") }) -> Bool {
        do {
            try spawn(launch(for: captured))
            return true
        } catch {
            logFailure("Rebased --on-close failed to spawn: \(error.localizedDescription)")
            return false
        }
    }

    private static func spawnProcess(_ launch: Launch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.argv[0])
        process.arguments = Array(launch.argv.dropFirst())
        if let cwd = launch.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        process.environment = launch.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
