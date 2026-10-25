import Foundation

/// The mutagen sessions that keep a mirror's working tree, and the host's `~/.m2/repository`, in step with the host.
/// A session belongs to one state directory: mutagen's daemon is shared by every agterm instance on this Mac.
public enum RebasedMirrorSync {
    public static let candidates = ["/opt/homebrew/bin/mutagen", "/usr/local/bin/mutagen"]

    public static func binary(candidates: [String] = candidates,
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        candidates.first(where: isExecutable)
    }

    public static func stateID(stateDirectory: URL) -> String {
        RebasedMirror.hash(RebasedMirrorCleanup.projectPath(stateDirectory))
    }

    public static func treeName(state: String, host: String, top: String) -> String {
        "agterm-\(state)-\(RebasedMirror.hash(host))-\(RebasedMirror.hash(top))"
    }

    public static func m2Name(state: String, host: String) -> String {
        "agterm-\(state)-m2-\(RebasedMirror.hash(host))"
    }

    public static func m2Directory(host: String, stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("rebased/m2", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent("repository", isDirectory: true)
    }

    /// Generated sources stay: without them a Maven module that generates code is red in the IDE.
    public static let treeIgnores = [".idea/", "node_modules/", "**/target/*",
                                     "!**/target/generated-sources/", "!**/target/generated-test-sources/"]

    // The global configuration could change modes or ignores under the session, so it is never read.
    private static func create(_ binary: String, name: String, state: String, kind: String) -> [String] {
        [binary, "sync", "create", "--no-global-configuration", "--name", name,
         "--label", "agterm-state=\(state)", "--label", "agterm-kind=\(kind)"]
    }

    public static func createTree(binary: String, state: String, host: String, top: String, clone: URL) -> [String] {
        create(binary, name: treeName(state: state, host: host, top: top), state: state, kind: "tree")
            + ["--mode", "one-way-replica", "--ignore-vcs"] + treeIgnores.flatMap { ["--ignore", $0] }
            + ["--default-file-mode-beta", "0444", "--default-directory-mode-beta", "0755", "\(host):\(top)", clone.path]
    }

    public static func createM2(binary: String, state: String, host: String, stateDirectory: URL) -> [String] {
        create(binary, name: m2Name(state: state, host: host), state: state, kind: "m2")
            + ["--mode", "one-way-safe", "\(host):.m2/repository", m2Directory(host: host, stateDirectory: stateDirectory).path]
    }

    public static func list(binary: String, state: String) -> [String] {
        [binary, "sync", "list", "--label-selector", "agterm-state=\(state)", "--template", "{{json .}}"]
    }

    public static func flush(binary: String, name: String) -> [String] { [binary, "sync", "flush", name] }
    public static func resume(binary: String, name: String) -> [String] { [binary, "sync", "resume", name] }
    public static func terminate(binary: String, name: String) -> [String] { [binary, "sync", "terminate", name] }

    /// The fields agterm reads from one session of `sync list`; anything else mutagen adds is ignored.
    public struct Session: Equatable, Sendable {
        public let name: String
        public let kind: String?
        public let status: String
        public let paused: Bool
        public let error: String?
        public let betaPath: String
        public let alphaFiles: Int?
        public let betaFiles: Int?
        /// A problem at the root: the cycle applied nothing, though mutagen still counts it as successful.
        public let rootProblem: String?
        /// Problems with single paths (an absolute symlink, a case collision); the rest of the tree syncs.
        public let fileProblems: Int
        /// Paths written on both sides; one-way-safe keeps the beta's copy.
        public let conflictRoots: [String]

        public var halted: Bool { status.hasPrefix("halted") }
        /// A lower `betaFiles` alone is no sign: a case collision keeps it below `alphaFiles` for good.
        public var copying: Bool {
            ["scanning", "staging-beta", "transitioning"].contains(status) || (betaFiles ?? 0) == 0 && (alphaFiles ?? 0) > 0
        }

        public init(name: String, kind: String?, status: String, paused: Bool = false, error: String? = nil, betaPath: String,
                    alphaFiles: Int? = nil, betaFiles: Int? = nil, rootProblem: String? = nil, fileProblems: Int = 0,
                    conflictRoots: [String] = []) {
            self.name = name
            self.kind = kind
            self.status = status
            self.paused = paused
            self.error = error
            self.betaPath = betaPath
            self.alphaFiles = alphaFiles
            self.betaFiles = betaFiles
            self.rootProblem = rootProblem
            self.fileProblems = fileProblems
            self.conflictRoots = conflictRoots
        }
    }

    /// What `sync list` answered: nil when this Mac has no mutagen, a failure's reason, or the sessions.
    public typealias Listing = Result<[Session], ListFailure>?

    public struct ListFailure: LocalizedError, Equatable {
        public let reason: String
        public var errorDescription: String? { reason }

        public init(reason: String) {
            self.reason = reason
        }
    }

    /// The tree session whose beta is `clone`, as the read-back reports it.
    public static func syncState(clone: URL, listing: Listing) -> ControlRebasedMirrorSync {
        switch listing {
        case nil: return ControlRebasedMirrorSync(state: "none")
        case .failure(let failure)?: return ControlRebasedMirrorSync(state: "unknown", error: failure.reason)
        case .success(let sessions)?:
            let path = RebasedMirrorCleanup.projectPath(clone)
            guard let session = sessions.first(where: {
                $0.kind == "tree" && RebasedMirrorCleanup.projectPath(URL(fileURLWithPath: $0.betaPath)) == path
            }) else { return ControlRebasedMirrorSync(state: "none") }
            return ControlRebasedMirrorSync(state: session.paused ? "paused" : session.status)
        }
    }

    public static func sessions(fromListOutput output: Data) throws -> [Session] {
        try JSONDecoder().decode([Listed].self, from: output).map(\.session)
    }

    private struct Problem: Decodable {
        let path: String
        let error: String
    }

    private struct Endpoint: Decodable {
        let path: String
        let files: Int?
        let scanProblems: [Problem]?
        let transitionProblems: [Problem]?
    }

    private struct Conflict: Decodable {
        let root: String
    }

    private struct Listed: Decodable {
        let name: String?
        let labels: [String: String]?
        let status: String
        let paused: Bool?
        let lastError: String?
        let alpha: Endpoint
        let beta: Endpoint
        let conflicts: [Conflict]?

        var session: Session {
            let problems = [beta.transitionProblems, alpha.transitionProblems, beta.scanProblems, alpha.scanProblems]
                .flatMap { $0 ?? [] }
            return Session(name: name ?? "", kind: labels?["agterm-kind"], status: status, paused: paused ?? false,
                           error: lastError, betaPath: beta.path, alphaFiles: alpha.files, betaFiles: beta.files,
                           rootProblem: problems.first { $0.path.isEmpty }?.error,
                           fileProblems: problems.filter { !$0.path.isEmpty }.count,
                           conflictRoots: conflicts?.map(\.root) ?? [])
        }
    }
}
