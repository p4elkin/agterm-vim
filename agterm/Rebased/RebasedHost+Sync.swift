import Foundation
import agtermCore
import os

/// The mutagen side of a mirror's lifecycle: a prune ends a mirror's sessions before deleting it, and the first IDE
/// start of a process ends sessions whose mirror went some other way. The m2 copy is never deleted.
extension RebasedHost {
    private nonisolated static let syncLogger = Logger(subsystem: "com.umputun.agterm", category: "RebasedHostSync")

    /// Lists once a mirror is about to go, or after a prune with entries to report, and never twice, so each entry
    /// carries its session as it was before any terminate; a prune with nothing to report never calls mutagen.
    nonisolated static func syncedPrune(_ request: RebasedMirrorCleanup.Request,
                                        sync: RebasedMirrorRefresh.Sync) -> RebasedMirrorCleanup.Report {
        guard let binary = sync.binary() else {
            return RebasedMirrorCleanup.prune(request).withSync { _ in ControlRebasedMirrorSync(state: "none") }
        }
        let state = RebasedMirrorSync.stateID(stateDirectory: request.stateDirectory)
        var listed: Result<[RebasedMirrorSync.Session], RebasedMirrorSync.ListFailure>?
        func sessions() throws -> [RebasedMirrorSync.Session] {
            if listed == nil { listed = list(binary: binary, state: state, run: sync.run) }
            return try (listed ?? .success([])).get()
        }
        let hooks = RebasedMirrorCleanup.Hooks(beforeRemove: { record in
            let clone = RebasedMirrorCleanup.projectPath(record.clone)
            for session in try sessions() where session.kind == "tree"
                && RebasedMirrorCleanup.projectPath(URL(fileURLWithPath: session.betaPath)) == clone {
                try terminate(session.name, binary: binary, run: sync.run)
            }
        }, hostEmptied: { host in
            let name = RebasedMirrorSync.m2Name(state: state, host: host)
            guard let listed = try? sessions(), listed.contains(where: { $0.name == name }) else { return }
            do {
                try terminate(name, binary: binary, run: sync.run)
            } catch {
                syncLogger.error("ending \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        })
        let report = RebasedMirrorCleanup.prune(request, hooks: hooks)
        guard !report.removed.isEmpty || !report.kept.isEmpty else { return report }
        let listing = listed ?? list(binary: binary, state: state, run: sync.run)
        return report.withSync { RebasedMirrorSync.syncState(clone: $0.clone, listing: listing) }
    }

    /// The list's own `sync list`, off the mirror queue so a long refresh never holds it.
    nonisolated static func withSync(_ records: [RebasedMirrorRecord], stateDirectory: URL,
                                     sync: RebasedMirrorRefresh.Sync) -> [RebasedMirrorRecord] {
        guard !records.isEmpty else { return records }
        let listing = sync.binary().map {
            list(binary: $0, state: RebasedMirrorSync.stateID(stateDirectory: stateDirectory), run: sync.run)
        }
        return records.map { record in
            var record = record
            record.sync = RebasedMirrorSync.syncState(clone: record.clone, listing: listing)
            return record
        }
    }

    /// Ends this state directory's tree sessions whose `<hash>/mirror.json` is gone (mutagen rebuilds a deleted beta
    /// root, so the beta path proves nothing) and m2 sessions whose host has no mirrors left. Errors only log.
    nonisolated static func sweepSessions(stateDirectory: URL, sync: RebasedMirrorRefresh.Sync) {
        guard let binary = sync.binary() else { return }
        let state = RebasedMirrorSync.stateID(stateDirectory: stateDirectory)
        let mirrors = stateDirectory.appendingPathComponent("rebased/mirrors", isDirectory: true)
        let sessions: [RebasedMirrorSync.Session]
        switch list(binary: binary, state: state, run: sync.run) {
        case .success(let listed): sessions = listed
        case .failure(let failure):
            return syncLogger.error("the mirror sweep could not list sessions: \(failure.reason, privacy: .public)")
        }
        let fm = FileManager.default
        for session in sessions {
            let beta = URL(fileURLWithPath: session.betaPath)
            let orphan: Bool
            switch session.kind {
            case "tree": orphan = !fm.fileExists(atPath: beta.deletingLastPathComponent()
                .appendingPathComponent(RebasedMirrorMarker.fileName).path)
            case "m2": orphan = !fm.fileExists(atPath: mirrors.appendingPathComponent(beta.deletingLastPathComponent().lastPathComponent).path)
            default: orphan = false
            }
            guard orphan else { continue }
            do {
                try terminate(session.name, binary: binary, run: sync.run)
            } catch {
                syncLogger.error("the mirror sweep could not end \(session.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Once per process, behind the start prune on the mirror queue, so `launch` never waits for it.
    func enqueueSweep() {
        let sync = sync, directory = stateDirectory
        guard !swept, sync.binary() != nil else { return }
        swept = true
        onMirrorQueue({ Self.sweepSessions(stateDirectory: directory, sync: sync) }, {})
    }

    struct SyncFailure: Error, LocalizedError {
        let errorDescription: String?
    }

    private nonisolated static func list(binary: String, state: String, run: RebasedMirrorRefresh.Sync.Run)
        -> Result<[RebasedMirrorSync.Session], RebasedMirrorSync.ListFailure> {
        let outcome = run(RebasedMirrorSync.list(binary: binary, state: state), RebasedMirrorRefresh.syncCallTimeout)
        guard outcome.status == 0 else { return .failure(.init(reason: "mutagen sync list: \(outcome.reason)")) }
        do {
            return .success(try RebasedMirrorSync.sessions(fromListOutput: Data(outcome.stdout.utf8)))
        } catch {
            return .failure(.init(reason: "unreadable mutagen sync list: \(error.localizedDescription)"))
        }
    }

    private nonisolated static func terminate(_ name: String, binary: String, run: RebasedMirrorRefresh.Sync.Run) throws {
        let outcome = run(RebasedMirrorSync.terminate(binary: binary, name: name), RebasedMirrorRefresh.syncCallTimeout)
        guard outcome.status == 0 else { throw SyncFailure(errorDescription: "mutagen sync terminate \(name): \(outcome.reason)") }
    }
}
