import Foundation
import agtermCore

/// Runs a `RebasedMirror`'s ssh and git steps, blocking; `RebasedHost` calls it off the main actor.
enum RebasedMirrorRefresh {
    struct Copy: Equatable, Sendable {
        let directory: String
        let source: String
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    // the first fetch copies the whole repository
    static let fetchTimeout: TimeInterval = 300
    static let queryTimeout: TimeInterval = 30

    static func run(_ mirror: RebasedMirror, stateDirectory: URL) -> Result<Copy, Failure> {
        let query = execute(mirror.toplevelCommand, timeout: queryTimeout)
        guard query.status == 0, let top = RebasedMirror.toplevel(fromOutput: query.stdout) else {
            return .failure(Failure(message: "\(mirror.host) found no repository at \(mirror.path): \(query.reason)"))
        }
        let directory = mirror.directory(top: top, stateDirectory: stateDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(Failure(message: "cannot create \(directory.path): \(error.localizedDescription)"))
        }
        for command in mirror.refreshCommands(top: top, directory: directory.path) {
            let step = execute(command, timeout: fetchTimeout)
            guard step.status == 0 else {
                return .failure(Failure(message: "mirroring \(mirror.source(top: top)) failed: \(step.reason)"))
            }
        }
        return .success(Copy(directory: directory.path, source: mirror.source(top: top)))
    }

    private struct Outcome {
        let status: Int32
        let stdout: String
        let reason: String
    }

    private static func execute(_ argv: [String], timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(RebasedMirror.environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        guard let capture = try? ProcessOutputCapture(attachingTo: process) else {
            return Outcome(status: -1, stdout: "", reason: "no pipe")
        }
        defer { capture.cancel() }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { @Sendable _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Outcome(status: -1, stdout: "", reason: error.localizedDescription)
        }
        capture.didLaunch()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return Outcome(status: -1, stdout: "", reason: "no answer within \(Int(timeout)) s")
        }
        let output = capture.collect(until: .now() + ProcessOutputCapture.terminationGrace)
        let lastLine = output?.stderr.split(whereSeparator: \.isNewline).last.map(String.init)
        return Outcome(status: process.terminationStatus, stdout: output?.stdout ?? "",
                       reason: lastLine ?? "exit \(process.terminationStatus)")
    }
}
