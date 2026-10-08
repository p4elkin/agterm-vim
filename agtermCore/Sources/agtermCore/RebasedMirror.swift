import Foundation

/// A Mac copy of a repository on a remote row's host, for an IDE that reads only this Mac's disk.
/// It holds the host's branches, tags and HEAD; uncommitted work on the host is not in it.
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
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in top.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return stateDirectory.appendingPathComponent("rebased/mirrors", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16), isDirectory: true)
            .appendingPathComponent(URL(fileURLWithPath: top).lastPathComponent, isDirectory: true)
    }

    public func source(top: String) -> String { host + ":" + top }

    /// HEAD is detached so the fetch may move every branch, and a range names the host's refs unchanged:
    /// `origin/x` resolves only because the host's remote-tracking refs are copied too.
    public func refreshCommands(top: String, directory: String) -> [[String]] {
        let git = "/usr/bin/git"
        return [
            [git, "init", "-q", directory],
            [git, "-C", directory, "fetch", "-q", "--prune", "--force", "--update-head-ok", source(top: top),
             "+refs/heads/*:refs/heads/*", "+refs/remotes/*:refs/remotes/*", "+refs/tags/*:refs/tags/*",
             "+HEAD:refs/agterm/head"],
            [git, "-C", directory, "checkout", "-q", "--force", "--detach", "refs/agterm/head"],
        ]
    }

    /// The repository `source` mirrors holds `path` on `host`.
    public static func covers(source: String, host: String, path: String) -> Bool {
        guard source.hasPrefix(host + ":") else { return false }
        let top = String(source.dropFirst(host.count + 1))
        return path == top || path.hasPrefix(top.hasSuffix("/") ? top : top + "/")
    }
}
