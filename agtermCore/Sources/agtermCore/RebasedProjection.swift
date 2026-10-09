public struct ControlRebasedViewNode: Codable, Sendable, Equatable {
    public let request: String
    public let kind: String
    public let target: String
    public let state: String
    public let detail: String?

    public init(request: String, kind: String, target: String, state: String, detail: String? = nil) {
        self.request = request
        self.kind = kind
        self.target = target
        self.state = state
        self.detail = detail
    }
}

public struct ControlRebasedOverlayNode: Codable, Sendable, Equatable {
    public let project: String
    public let state: String
    public let error: String?
    public let diff: String?
    public let source: String?
    public let pane: String?
    public let hidden: Bool?
    public let view: ControlRebasedViewNode?
    public let onClose: Bool?

    public init(project: String, state: String, error: String? = nil, diff: String? = nil, source: String? = nil,
                pane: String? = nil, hidden: Bool? = nil, view: ControlRebasedViewNode? = nil, onClose: Bool? = nil) {
        self.project = project
        self.state = state
        self.error = error
        self.diff = diff
        self.source = source
        self.pane = pane
        self.hidden = hidden
        self.view = view
        self.onClose = onClose
    }
}

public struct ControlRebasedNode: Codable, Sendable, Equatable {
    public let jvm: String
    public let error: String?
    public let projects: [String]
    public let port: Int?

    public init(jvm: String, error: String? = nil, projects: [String] = [], port: Int? = nil) {
        self.jvm = jvm
        self.error = error
        self.projects = projects
        self.port = port
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
    var controlNode: ControlRebasedOverlayNode { controlNode(pane: nil) }

    func controlNode(pane: OverlayPane?) -> ControlRebasedOverlayNode {
        let stateName: String
        var error: String?
        switch state {
        case .fetching: stateName = "fetching"
        case .starting: stateName = "starting"
        case .shown: stateName = "shown"
        case .failed(let detail): stateName = "failed"; error = detail
        }
        return .init(project: project, state: stateName, error: error, diff: diff?.spec, source: source,
                     pane: pane?.rawValue, hidden: hidden, view: view.map {
                         ControlRebasedViewNode(request: $0.id, kind: $0.kind.rawValue, target: $0.target,
                                                state: $0.state.rawValue, detail: $0.detail)
                     }, onClose: onClose == nil ? nil : true)
    }
}
