import Foundation
import OSLog
import agtermCore

private let onCloseLogger = Logger(subsystem: "com.umputun.agterm", category: "RebasedOnClose")

enum RebasedOnCloseRunner {
    @discardableResult
    static func run(_ captured: RebasedOnClose, logFailure: (String) -> Void = { onCloseLogger.error("\($0, privacy: .public)") }) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", captured.command]
        process.currentDirectoryURL = URL(fileURLWithPath: captured.cwd, isDirectory: true)
        process.environment = captured.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            logFailure("Rebased --on-close failed to spawn: \(error.localizedDescription)")
            return false
        }
    }
}
