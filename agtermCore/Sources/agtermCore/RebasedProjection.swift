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
