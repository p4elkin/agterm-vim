import Foundation

/// Finds what a `RebasedMirror` left on disk, so mirrors nobody uses can be removed with the IDE's data for them.
public enum RebasedMirrorCleanup {
    /// The path the host gives the IDE for a clone; the IDE names its per-project data after this exact string.
    public static func projectPath(_ clone: URL) -> String {
        clone.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The `<hash>` directory of a clone at `<stateDir>/rebased/mirrors/<host>/<hash>/<name>`; nil for any other path.
    public static func hashDirectory(ofClone clone: URL, stateDirectory: URL) -> URL? {
        let root = projectPath(Roots(stateDirectory).mirrors), path = projectPath(clone)
        guard path.hasPrefix(root + "/"), path.dropFirst(root.count + 1).split(separator: "/").count == 3 else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
    }

    /// Java's `String.hashCode()` printed as `Integer.toHexString` does: IntelliJ's suffix for per-project data.
    public static func javaHash(_ path: String) -> String {
        var hash: UInt32 = 0
        for unit in path.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return String(hash, radix: 16)
    }

    /// The name holds `hash`, bare or zero-padded to 8 digits, as a part between `.`, `-` and `_`.
    static func names(_ name: String, hash: String) -> Bool {
        let padded = String(repeating: "0", count: max(0, 8 - hash.count)) + hash
        return name.split(whereSeparator: { ".-_".contains($0) }).contains { $0 == hash || $0 == padded }
    }

    // Only directories holding one entry per project; index, caches and LocalHistory are shared by every project,
    // and compile-server names its entries with a different hash.
    static let perProjectDirectories = ["projects", "editor", "compiler", "vcs-log", "vcs-users", "frameworks/detection"]

    /// The IDE's entries for `projectPath` under its `system` directory.
    public static func ideEntries(projectPath: String, systemDirectory: URL) -> [URL] {
        ideEntries(hash: javaHash(projectPath), systemDirectory: systemDirectory)
    }

    static func ideEntries(hash: String, systemDirectory: URL) -> [URL] {
        perProjectDirectories.flatMap { directory -> [URL] in
            let parent = systemDirectory.appendingPathComponent(directory, isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            return children.filter { names($0, hash: hash) }.map { parent.appendingPathComponent($0) }
        }
        .sorted { $0.path < $1.path }
    }

    /// Every mirror under `<stateDir>/rebased/mirrors`. Symlinked `<host>` and `<hash>` entries are skipped, and
    /// an entry that vanishes while the walk runs is left out.
    public static func scan(stateDirectory: URL, inUse: Set<String>, measure: Bool) -> [RebasedMirrorRecord] {
        scan(stateDirectory: stateDirectory, inUse: inUse, measure: measure) { _ in }
    }

    static func scan(stateDirectory: URL, inUse: Set<String>, measure: Bool,
                     afterListing: (_ host: URL) -> Void) -> [RebasedMirrorRecord] {
        directories(in: Roots(stateDirectory).mirrors).flatMap { host in
            records(host: host, inUse: inUse, measure: measure, afterListing: afterListing)
        }
    }

    private static func records(host: URL, inUse: Set<String>, measure: Bool,
                                afterListing: (_ host: URL) -> Void = { _ in }) -> [RebasedMirrorRecord] {
        let hashes = directories(in: host)
        afterListing(host)
        return hashes.compactMap { hashDirectory in
            let marker = RebasedMirrorMarker.read(from: hashDirectory)
            guard let lastOpened = lastOpened(hashDirectory: hashDirectory, marker: marker) else { return nil }
            let clone = clone(in: hashDirectory)
            return RebasedMirrorRecord(host: host.lastPathComponent, source: marker?.source,
                                       clone: clone, hashDirectory: hashDirectory, lastOpened: lastOpened,
                                       bytes: measure ? size(of: hashDirectory) : nil, inUse: inUse.contains(projectPath(clone)))
        }
    }

    public struct Request: Sendable {
        public let stateDirectory: URL
        public let inUse: Set<String>
        public let maxAgeDays: Int
        public let dryRun: Bool
        public let now: Date
        public let measure: Bool

        public init(stateDirectory: URL, inUse: Set<String>, maxAgeDays: Int, dryRun: Bool, now: Date = Date(), measure: Bool = false) {
            precondition(maxAgeDays >= 1, "a prune needs maxAgeDays of 1 or more")
            self.stateDirectory = stateDirectory
            self.inUse = inUse
            self.maxAgeDays = maxAgeDays
            self.dryRun = dryRun
            self.now = now
            self.measure = measure
        }

        func isStale(_ lastOpened: Date) -> Bool {
            now.timeIntervalSince(lastOpened) >= TimeInterval(maxAgeDays) * 86_400
        }
    }

    public struct Report: Equatable, Sendable {
        /// `error` says why a removal failed and the mirror stayed.
        public struct Entry: Equatable, Sendable {
            public let mirror: RebasedMirrorRecord
            public let ideData: [URL]
            public let error: String?
        }

        /// Removed, or on a dry run, would be removed.
        public let removed: [Entry]
        /// In use, or failed to remove.
        public let kept: [Entry]
        public let dryRun: Bool
        public let olderThanDays: Int

        public init(removed: [Entry], kept: [Entry], dryRun: Bool, olderThanDays: Int) {
            self.removed = removed
            self.kept = kept
            self.dryRun = dryRun
            self.olderThanDays = olderThanDays
        }
    }

    /// Removes each mirror not in use and last opened at least `maxAgeDays` ago, its IDE entries first.
    /// A fresh mirror, and a stale one that vanishes or freshens before its delete, is left out of the report.
    public static func prune(_ request: Request) -> Report {
        prune(request) { _ in }
    }

    static func prune(_ request: Request, beforeDelete: (RebasedMirrorRecord) -> Void) -> Report {
        let roots = Roots(request.stateDirectory)
        var removed: [Report.Entry] = []
        var kept: [Report.Entry] = []
        for host in directories(in: roots.mirrors) {
            for record in records(host: host, inUse: request.inUse, measure: request.measure) {
                if record.inUse {
                    kept.append(.init(mirror: record, ideData: [], error: nil))
                    continue
                }
                guard request.isStale(record.lastOpened) else { continue }
                if request.dryRun {
                    removed.append(.init(mirror: record, ideData: roots.ideEntries(of: record), error: nil))
                    continue
                }
                beforeDelete(record)
                guard isRealDirectory(record.hashDirectory), roots.contains(record.hashDirectory),
                      let again = lastOpened(hashDirectory: record.hashDirectory), request.isStale(again) else { continue }
                let ideData = roots.ideEntries(of: record)
                do {
                    for entry in ideData { try FileManager.default.removeItem(at: entry) }
                    try FileManager.default.removeItem(at: record.hashDirectory)
                    removed.append(.init(mirror: record, ideData: ideData, error: nil))
                } catch {
                    kept.append(.init(mirror: record, ideData: ideData, error: error.localizedDescription))
                }
            }
            // Never removeItem: it is recursive, and a host still holding a kept mirror or any other file must stay.
            if !request.dryRun { _ = rmdir(host.path) }
        }
        return Report(removed: removed, kept: kept, dryRun: request.dryRun, olderThanDays: request.maxAgeDays)
    }

    /// The two trees a prune deletes from, both derived from the state directory.
    private struct Roots {
        let mirrors: URL
        let system: URL

        init(_ stateDirectory: URL) {
            mirrors = stateDirectory.appendingPathComponent("rebased/mirrors", isDirectory: true)
            system = stateDirectory.appendingPathComponent("rebased/system", isDirectory: true)
        }

        func ideEntries(of record: RebasedMirrorRecord) -> [URL] {
            RebasedMirrorCleanup.ideEntries(projectPath: projectPath(record.clone), systemDirectory: system).filter(contains)
        }

        /// The parent's symlinks are resolved, so a symlinked `system/projects` cannot carry a delete outside.
        /// The entry's own are not: removing a symlink removes only the link.
        func contains(_ url: URL) -> Bool {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            return [mirrors, system].contains { root in
                let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
                return parent == rootPath || parent.hasPrefix(rootPath + "/")
            }
        }
    }

    /// The later of the marker's time and the clone's last fetch, else the `<hash>` directory's own time;
    /// nil once the directory is gone.
    static func lastOpened(hashDirectory: URL) -> Date? {
        lastOpened(hashDirectory: hashDirectory, marker: RebasedMirrorMarker.read(from: hashDirectory))
    }

    private static func lastOpened(hashDirectory: URL, marker: RebasedMirrorMarker?) -> Date? {
        guard let modified = modificationDate(hashDirectory) else { return nil }
        let fetched = modificationDate(clone(in: hashDirectory).appendingPathComponent(".git/FETCH_HEAD"))
        let times = [marker?.lastOpened, fetched].compactMap { $0 }
        return times.max() ?? modified
    }

    /// The `<name>` directory beside the marker, or the `<hash>` directory itself when it holds no clone.
    static func clone(in hashDirectory: URL) -> URL {
        directories(in: hashDirectory).first ?? hashDirectory
    }

    /// Real directories only, sorted; a symlink is never followed.
    static func directories(in parent: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.sorted().map { parent.appendingPathComponent($0, isDirectory: true) }.filter(isRealDirectory)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// One mirror as `scan` found it. `clone` is the `<hash>` directory when that holds no clone.
public struct RebasedMirrorRecord: Equatable, Sendable {
    public let host: String
    public let source: String?
    public let clone: URL
    public let hashDirectory: URL
    public let lastOpened: Date
    public let bytes: Int64?
    public let inUse: Bool

    public init(host: String, source: String?, clone: URL, hashDirectory: URL, lastOpened: Date, bytes: Int64?, inUse: Bool) {
        self.host = host
        self.source = source
        self.clone = clone
        self.hashDirectory = hashDirectory
        self.lastOpened = lastOpened
        self.bytes = bytes
        self.inUse = inUse
    }
}

extension ControlRebasedMirrors {
    /// The `rebased.mirror.list` answer.
    public init(mirrors: [RebasedMirrorRecord]) {
        self.init(mirrors: mirrors.map { ControlRebasedMirrorNode($0) })
    }

    /// The `rebased.mirror.prune` answer.
    public init(report: RebasedMirrorCleanup.Report) {
        let nodes = { (entries: [RebasedMirrorCleanup.Report.Entry]) in
            entries.map { ControlRebasedMirrorNode($0.mirror, ideData: $0.ideData.map(\.path), error: $0.error) }
        }
        self.init(removed: nodes(report.removed), kept: nodes(report.kept), dryRun: report.dryRun, olderThanDays: report.olderThanDays)
    }
}

extension ControlRebasedMirrorNode {
    init(_ record: RebasedMirrorRecord, ideData: [String]? = nil, error: String? = nil) {
        self.init(host: record.host, source: record.source, directory: record.clone.path,
                  lastOpened: record.lastOpened.timeIntervalSince1970, bytes: record.bytes.map { Int(clamping: $0) },
                  inUse: record.inUse, ideData: ideData, error: error)
    }
}
