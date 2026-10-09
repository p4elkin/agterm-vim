public struct ControlRebasedOverlayNode: Codable, Sendable, Equatable {
    public let project: String
    public let state: String
    public let error: String?
    public let diff: String?
    public let source: String?

    public init(project: String, state: String, error: String? = nil, diff: String? = nil, source: String? = nil) {
        self.project = project
        self.state = state
        self.error = error
        self.diff = diff
        self.source = source
    }
}

public struct ControlRebasedNode: Codable, Sendable, Equatable {
    public let jvm: String
    public let error: String?
    public let projects: [String]

    public init(jvm: String, error: String? = nil, projects: [String] = []) {
        self.jvm = jvm
        self.error = error
        self.projects = projects
    }
}

/// One mirror as `rebased.mirror.list` and `rebased.mirror.prune` report it.
public struct ControlRebasedMirrorNode: Codable, Sendable, Equatable {
    public let host: String
    public let source: String?
    /// The clone, or its `<hash>` directory when that holds no clone.
    public let directory: String
    /// Seconds since the Unix epoch.
    public let lastOpened: Double
    public let bytes: Int?
    public let inUse: Bool
    /// The IDE's per-project entries removed with the mirror, or that a dry run would remove; prune only.
    public let ideData: [String]?
    /// Why a prune kept a mirror it meant to remove.
    public let error: String?

    public init(host: String, source: String? = nil, directory: String, lastOpened: Double, bytes: Int? = nil,
                inUse: Bool, ideData: [String]? = nil, error: String? = nil) {
        self.host = host
        self.source = source
        self.directory = directory
        self.lastOpened = lastOpened
        self.bytes = bytes
        self.inUse = inUse
        self.ideData = ideData
        self.error = error
    }
}

/// list fills `mirrors`; prune fills the rest, `olderThanDays` being the age it actually used.
public struct ControlRebasedMirrors: Codable, Sendable, Equatable {
    public let mirrors: [ControlRebasedMirrorNode]?
    public let removed: [ControlRebasedMirrorNode]?
    public let kept: [ControlRebasedMirrorNode]?
    public let dryRun: Bool?
    public let olderThanDays: Int?

    public init(mirrors: [ControlRebasedMirrorNode]? = nil, removed: [ControlRebasedMirrorNode]? = nil,
                kept: [ControlRebasedMirrorNode]? = nil, dryRun: Bool? = nil, olderThanDays: Int? = nil) {
        self.mirrors = mirrors
        self.removed = removed
        self.kept = kept
        self.dryRun = dryRun
        self.olderThanDays = olderThanDays
    }
}

extension RebasedOverlay {
    var controlNode: ControlRebasedOverlayNode {
        switch state {
        case .fetching: .init(project: project, state: "fetching", diff: diff?.spec, source: source)
        case .starting: .init(project: project, state: "starting", diff: diff?.spec, source: source)
        case .shown: .init(project: project, state: "shown", diff: diff?.spec, source: source)
        case .failed(let error): .init(project: project, state: "failed", error: error, diff: diff?.spec, source: source)
        }
    }
}
