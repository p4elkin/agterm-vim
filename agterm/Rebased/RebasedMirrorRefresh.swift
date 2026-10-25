import Foundation
import agtermCore
import os

/// Runs a `RebasedMirror`'s ssh and git steps, blocking; `RebasedHost` calls it off the main actor.
enum RebasedMirrorRefresh {
    struct Copy: Equatable, Sendable {
        let directory: String
        let source: String
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// Mutagen, when this Mac has it. Only `RebasedHost.configure` installs `.installed`, so no test reaches a real one.
    struct Sync: Sendable {
        typealias Run = @Sendable (_ argv: [String], _ timeout: TimeInterval) -> Outcome
        let binary: @Sendable () -> String?
        let run: Run

        static let none = Sync(binary: { nil }, run: { _, _ in Outcome(status: -1, stdout: "", reason: "no mutagen") })
        static let installed = Sync(binary: { RebasedMirrorSync.binary() }, run: { runProcess($0, timeout: $1) })
    }

    static let queryTimeout: TimeInterval = 30
    static let syncCallTimeout: TimeInterval = 30
    static let createTimeout: TimeInterval = 60
    static let flushTimeout: TimeInterval = 240
    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "RebasedMirrorRefresh")

    static func run(_ mirror: RebasedMirror, stateDirectory: URL, sync: Sync,
                    execute: (_ argv: [String], _ timeout: TimeInterval) -> Outcome = runProcess) -> Result<Copy, Failure> {
        let query = execute(mirror.toplevelCommand, queryTimeout)
        guard query.status == 0, let top = RebasedMirror.toplevel(fromOutput: query.stdout) else {
            return .failure(Failure(message: "\(mirror.host) found no repository at \(mirror.path): \(query.reason)"))
        }
        let directory = mirror.directory(top: top, stateDirectory: stateDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(Failure(message: "cannot create \(directory.path): \(error.localizedDescription)"))
        }
        // written before the fetch too, so a refresh that fails mid-way still counts as opening the mirror
        func writeMarker() {
            try? RebasedMirrorMarker(source: mirror.source(top: top), lastOpened: Date()).write(to: directory.deletingLastPathComponent())
        }
        writeMarker()
        let binary = sync.binary()
        for step in mirror.refreshCommands(top: top, directory: directory.path, synced: binary != nil) {
            let outcome = execute(step.argv, step.timeout)
            guard outcome.status == 0 else {
                return .failure(Failure(message: "mirroring \(mirror.source(top: top)) failed: \(outcome.reason)"))
            }
        }
        if let binary, let failure = syncWorkingTree(mirror, top: top, stateDirectory: stateDirectory, binary: binary, run: sync.run) {
            return .failure(failure)
        }
        writeMarker()
        return .success(Copy(directory: directory.path, source: mirror.source(top: top)))
    }

    /// Lists, recovers or creates the tree session (and the host's m2 session), then flushes and checks the copy.
    private static func syncWorkingTree(_ mirror: RebasedMirror, top: String, stateDirectory: URL,
                                        binary: String, run: (_ argv: [String], _ timeout: TimeInterval) -> Outcome) -> Failure? {
        let source = mirror.source(top: top), state = RebasedMirrorSync.stateID(stateDirectory: stateDirectory)
        let clone = mirror.directory(top: top, stateDirectory: stateDirectory)
        let treeName = RebasedMirrorSync.treeName(state: state, host: mirror.host, top: top)
        func failure(_ reason: String) -> Failure { Failure(message: "syncing \(source) failed: \(reason)") }
        func list() -> Result<[RebasedMirrorSync.Session], Failure> {
            let listed = run(RebasedMirrorSync.list(binary: binary, state: state), syncCallTimeout)
            guard listed.status == 0 else { return .failure(failure(listed.reason)) }
            do {
                return .success(try RebasedMirrorSync.sessions(fromListOutput: Data(listed.stdout.utf8)))
            } catch {
                return .failure(failure("unreadable mutagen sync list: \(error.localizedDescription)"))
            }
        }
        func call(_ argv: [String], _ timeout: TimeInterval) -> Failure? {
            let outcome = run(argv, timeout)
            return outcome.status == 0 ? nil : failure(outcome.reason)
        }
        let sessions: [RebasedMirrorSync.Session]
        switch list() {
        case .success(let listed): sessions = listed
        case .failure(let failed): return failed
        }
        var tree = sessions.first { $0.name == treeName }
        if let halted = tree, halted.halted {
            if let failed = call(RebasedMirrorSync.terminate(binary: binary, name: treeName), syncCallTimeout) { return failed }
            tree = nil
        }
        if let tree {
            if tree.paused, let failed = call(RebasedMirrorSync.resume(binary: binary, name: treeName), syncCallTimeout) {
                return failed
            }
        } else {
            removeWriteBits(under: clone)
            let create = RebasedMirrorSync.createTree(binary: binary, state: state, host: mirror.host, top: top, clone: clone)
            if let failed = call(create, createTimeout) { return failed }
        }
        let m2 = RebasedMirrorSync.m2Directory(host: mirror.host, stateDirectory: stateDirectory)
        if !sessions.contains(where: { $0.name == RebasedMirrorSync.m2Name(state: state, host: mirror.host) }) {
            // `create` makes the beta root but not its parent, and a missing parent fails every cycle quietly
            do {
                try FileManager.default.createDirectory(at: m2.deletingLastPathComponent(), withIntermediateDirectories: true)
                let create = RebasedMirrorSync.createM2(binary: binary, state: state, host: mirror.host, stateDirectory: stateDirectory)
                if let failed = call(create, createTimeout) { logger.error("\(failed.message, privacy: .public)") }
            } catch {
                logger.error("cannot create \(m2.deletingLastPathComponent().path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let flushed = run(RebasedMirrorSync.flush(binary: binary, name: treeName), flushTimeout)
        let after: [RebasedMirrorSync.Session]
        switch list() {
        case .success(let listed): after = listed
        case .failure(let failed): return failed
        }
        if let m2Session = after.first(where: { $0.name == RebasedMirrorSync.m2Name(state: state, host: mirror.host) }) {
            dropConflicts(m2Session.conflictRoots, under: m2)
        }
        guard let synced = after.first(where: { $0.name == treeName }) else { return failure("the session \(treeName) is gone") }
        if let problem = synced.rootProblem { return failure(problem) }
        // a busy status after a good flush is the host writing again, not an unfinished first copy
        if flushed.status != 0 {
            return synced.copying ? Failure(message: "first sync of \(source) is still copying; open again") : failure(flushed.reason)
        }
        if (synced.betaFiles ?? 0) == 0, (synced.alphaFiles ?? 0) > 0 { return failure("no files arrived from \(source)") }
        if synced.fileProblems > 0 {
            logger.info("\(source, privacy: .public): \(synced.fileProblems) paths not synced, see mutagen sync list")
        }
        return nil
    }

    /// Mutagen writes `0444` only into files it changes; a file the checkout left identical keeps its write bits.
    static func removeWriteBits(under clone: URL) {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: clone, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in walk {
            if url.deletingLastPathComponent().standardizedFileURL == clone.standardizedFileURL,
               [".git", ".idea"].contains(url.lastPathComponent) {
                walk.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int,
                  mode & 0o222 != 0 else { continue }
            try? fm.setAttributes([.posixPermissions: mode & ~0o222], ofItemAtPath: url.path)
        }
    }

    /// One-way-safe keeps the Mac's copy of a path both sides wrote; deleting it lets the host's copy arrive next cycle.
    static func dropConflicts(_ roots: [String], under m2: URL) {
        let base = m2.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for root in roots {
            let target = m2.appendingPathComponent(root).standardizedFileURL
            // the parent's symlinks are resolved, so neither `.` nor a linked directory reaches outside the copy
            let resolved = target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent)
            guard resolved.standardizedFileURL.path.hasPrefix(base) else { continue }
            try? FileManager.default.removeItem(at: target)
        }
    }

    struct Outcome {
        let status: Int32
        let stdout: String
        let reason: String
    }

    static func runProcess(_ argv: [String], timeout: TimeInterval) -> Outcome {
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
