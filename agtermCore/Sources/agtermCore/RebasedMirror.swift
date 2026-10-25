import Foundation

/// A Mac copy of a repository on a remote row's host, for an IDE that reads only this Mac's disk.
/// It holds the host's branches, tags and HEAD; without mutagen, uncommitted work on the host is not in it.
public struct RebasedMirror: Equatable, Sendable {
    public let host: String
    public let path: String

    /// Nil for a host ssh would read as an option or a path, or a path that is not absolute.
    public init?(host: String, path: String) {
        let banned = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "/"))
        guard let first = host.first, first != "-", host.rangeOfCharacter(from: banned) == nil,
              path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        self.host = host
        self.path = path
    }

    public static let environment = ["GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=10", "GIT_TERMINAL_PROMPT": "0"]

    /// Asks the host for the top of the repository holding `path`: `git upload-pack` does not look upward.
    public var toplevelCommand: [String] {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host,
                "git -C \(quoted) rev-parse --show-toplevel"]
    }

    public static func toplevel(fromOutput output: String) -> String? {
        let top = output.trimmingCharacters(in: .newlines)
        guard top.hasPrefix("/"), top.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return top
    }

    /// `<stateDir>/rebased/mirrors/<host>/<hash>/<name>`: the last component is what the IDE calls the project.
    public func directory(top: String, stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("rebased/mirrors", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent(Self.hash(top), isDirectory: true)
            .appendingPathComponent(URL(fileURLWithPath: top).lastPathComponent, isDirectory: true)
    }

    /// FNV-1a in hex: stable across runs and machines, unlike `hashValue`.
    public static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    public func source(top: String) -> String { host + ":" + top }

    public struct RefreshStep: Equatable, Sendable {
        public let argv: [String]
        public let timeout: TimeInterval
    }

    /// HEAD is detached so the fetch may move every branch, and a range names the host's refs unchanged:
    /// `origin/x` resolves only because the host's remote-tracking refs are copied too.
    /// A synced mirror's working tree belongs to mutagen, so it only moves HEAD and the index:
    /// plain `read-tree -m` refuses once mutagen has changed a file (`not uptodate`), `-i` skips that check.
    public func refreshCommands(top: String, directory: String, synced: Bool) -> [RefreshStep] {
        let git = "/usr/bin/git"
        let fetch = [git, "-C", directory, "fetch", "-q", "--prune", "--force", "--update-head-ok", source(top: top),
                     "+refs/heads/*:refs/heads/*", "+refs/remotes/*:refs/remotes/*", "+refs/tags/*:refs/tags/*",
                     "+HEAD:refs/agterm/head"]
        let head: [RefreshStep] = synced
            ? [RefreshStep(argv: [git, "-C", directory, "update-ref", "--no-deref", "HEAD", "refs/agterm/head"], timeout: 30),
               RefreshStep(argv: [git, "-C", directory, "read-tree", "-m", "-i", "refs/agterm/head"], timeout: 30)]
            : [RefreshStep(argv: [git, "-C", directory, "checkout", "-q", "--force", "--detach", "refs/agterm/head"], timeout: 300)]
        return [RefreshStep(argv: [git, "init", "-q", directory], timeout: 30), RefreshStep(argv: fetch, timeout: 300)] + head
    }

    /// `hostPath` inside the mirror `directory` of `top`; nil outside `top`, after `..` is resolved.
    public static func mirrorPath(hostPath: String, top: String, directory: String) -> String? {
        let path = URL(fileURLWithPath: hostPath).standardized.path
        if path == top { return directory }
        guard path.hasPrefix(top + "/") else { return nil }
        return directory + path.dropFirst(top.count)
    }

    /// The repository `source` mirrors holds `path` on `host`.
    public static func covers(source: String, host: String, path: String) -> Bool {
        guard source.hasPrefix(host + ":") else { return false }
        let top = String(source.dropFirst(host.count + 1))
        return path == top || path.hasPrefix(top.hasSuffix("/") ? top : top + "/")
    }
}
