import Foundation

public struct RebasedFileTarget: Equatable, Sendable {
    public let path: String
    public let line: Int

    public init?(spec: String) {
        guard !spec.isEmpty, !spec.contains("\t"),
              !spec.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { return nil }
        if let colon = spec.lastIndex(of: ":") {
            let suffix = spec[spec.index(after: colon)...]
            guard !suffix.isEmpty else { return nil }
            if suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                guard let line = Int(suffix), line >= 1, colon != spec.startIndex else { return nil }
                self.path = String(spec[..<colon])
                self.line = line
                return
            }
        }
        self.path = spec
        self.line = 0
    }
}

public enum RebasedView: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case diff
        case workingTree = "working-tree"
        case file
    }

    case diff(RebasedDiff, workingTree: Bool)
    case file(path: String, line: Int)

    public init?(diff spec: String, workingTree: Bool = false) {
        guard let diff = RebasedDiff(spec: spec) else { return nil }
        if workingTree && !diff.mergeBase {
            let parts = spec.components(separatedBy: "..")
            guard parts.count == 1 || parts[1].isEmpty else { return nil }
        }
        self = .diff(diff, workingTree: workingTree)
    }

    public var kind: Kind {
        switch self {
        case .diff(_, workingTree: true): .workingTree
        case .diff: .diff
        case .file: .file
        }
    }

    public var target: String {
        switch self {
        case .diff(let diff, _): diff.spec
        case .file(let path, _): path
        }
    }

    public var bridgeVerb: String {
        switch self {
        case .diff: "diff"
        case .file: "openFile"
        }
    }

    public func bridgeArgument(request: String, project: String, pane: Bool) -> String {
        switch self {
        case .diff(let diff, let workingTree):
            diff.bridgeArgument(request: request, workingTree: workingTree, pane: pane, project: project)
        case .file(let path, let line):
            [request, String(line), path, project].joined(separator: "\t")
        }
    }
}

public struct RebasedViewRequest: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case queued, sent, opened, failed
    }

    public enum Event: Equatable, Sendable {
        case opened(String)
        case failed(String)
    }

    public private(set) var id: String
    public private(set) var view: RebasedView
    public private(set) var state: State
    public private(set) var detail: String?
    public var kind: RebasedView.Kind { view.kind }
    public var target: String { view.target }

    public init(view: RebasedView) {
        self.id = UUID().uuidString
        self.view = view
        self.state = .queued
    }

    @discardableResult
    public mutating func issue(_ view: RebasedView) -> String {
        self = Self(view: view)
        return id
    }

    public mutating func sent() {
        guard state == .queued else { return }
        state = .sent
    }

    @discardableResult
    public mutating func apply(event: Event, request: String) -> Bool {
        guard request == id, state == .sent else { return false }
        switch event {
        case .opened(let detail):
            state = .opened
            self.detail = detail
        case .failed(let reason):
            state = .failed
            detail = reason
        }
        return true
    }

    @discardableResult
    public mutating func timedOut(request: String) -> Bool {
        guard request == id, state == .sent else { return false }
        return apply(event: .failed("view request timed out"), request: request)
    }
}

public struct RebasedOnClose: Equatable, Sendable {
    public let command: String
    public let cwd: String
    public let environment: [String: String]

    public init(command: String, cwd: String, environment: [String: String]) {
        self.command = command
        self.cwd = cwd
        self.environment = environment
    }
}
