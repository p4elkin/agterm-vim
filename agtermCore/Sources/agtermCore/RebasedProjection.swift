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
