import agtermCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The `--html` pages this origin serves to a presenting Mac, each folder under its own random token. The page
/// server's threads read it, so every access takes the lock.
public final class HeadlessPages: @unchecked Sendable {
    public static let limit = 64

    public enum Publication: Equatable, Sendable {
        /// `path` is the file under the served root, `/`-separated and not encoded.
        case published(token: String, path: String)
        case refused(String)
    }

    private struct Entry {
        let root: String
        let session: UUID
        let order: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var published = 0
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// Serves `file`'s folder, or `grantRoot` when given, by the rule the Mac applies to a local `--html` page.
    public func publish(file: String, grantRoot: String?, session: UUID) -> Publication {
        if let error = HtmlOverlay.grantError(file: file, grantRoot: grantRoot, home: home) { return .refused(error) }
        guard let realFile = Self.realPath(file), Self.isRegularFile(realFile) else {
            return .refused("html file not found: \(file)")
        }
        let root = grantRoot ?? (file as NSString).deletingLastPathComponent
        guard let realRoot = Self.realPath(root), let path = Self.relative(realFile, under: realRoot) else {
            return .refused("html file is outside cwd")
        }
        let token = UUID().uuidString.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= Self.limit, let oldest = entries.min(by: { $0.value.order < $1.value.order }) {
            entries[oldest.key] = nil
        }
        published += 1
        entries[token] = Entry(root: realRoot, session: session, order: published)
        return .published(token: token, path: path)
    }

    /// The file a request path names: `/<token>/<path>`, percent-decoded, resolved with symlinks and still inside
    /// the token's root. Nil for anything else.
    public func file(forPath requestPath: String) -> String? {
        let bare = String(requestPath.prefix { $0 != "?" && $0 != "#" })
        let parts = bare.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].isEmpty else { return nil }
        let rest = parts[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard rest.count == 2, let path = String(rest[1]).removingPercentEncoding, !path.isEmpty else { return nil }
        lock.lock()
        let root = entries[String(rest[0])]?.root
        lock.unlock()
        guard let root, let real = Self.realPath(root + "/" + path), Self.isRegularFile(real),
              Self.relative(real, under: root) != nil else { return nil }
        return real
    }

    public func forget(token: String) {
        lock.lock()
        entries[token] = nil
        lock.unlock()
    }

    public func forget(session: UUID) {
        lock.lock()
        entries = entries.filter { $0.value.session != session }
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// `path` below `root` by whole components, nil when it is not strictly inside.
    static func relative(_ path: String, under root: String) -> String? {
        let rootParts = root.split(separator: "/")
        let parts = path.split(separator: "/")
        guard parts.count > rootParts.count, parts.starts(with: rootParts) else { return nil }
        return parts.dropFirst(rootParts.count).joined(separator: "/")
    }
}
