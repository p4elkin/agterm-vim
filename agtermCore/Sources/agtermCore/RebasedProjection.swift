public struct ControlRebasedOverlayNode: Codable, Sendable, Equatable {
    public let project: String
    public let state: String
    public let error: String?

    public init(project: String, state: String, error: String? = nil) {
        self.project = project
        self.state = state
        self.error = error
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
        case .starting: .init(project: project, state: "starting")
        case .shown: .init(project: project, state: "shown")
        case .failed(let error): .init(project: project, state: "failed", error: error)
        }
    }
}
