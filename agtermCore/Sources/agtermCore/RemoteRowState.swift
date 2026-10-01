import Foundation

public enum RemoteRowState: String, Codable, Equatable, Sendable {
    case attached
    case disconnected
    case endedOnHost

    public static func classify(tree: ControlResponse, binding: RemoteBinding) -> RemoteRowState? {
        guard let origin = binding.origin else { return nil }
        guard tree.ok, let remote = tree.result?.remote, remote.endpoint == origin.endpoint else { return .disconnected }
        return remote.sessions.contains { $0.id == binding.remoteSessionID } ? .attached : .endedOnHost
    }

    public func rowNotice(host: String) -> String? {
        switch self {
        case .attached: return nil
        case .disconnected: return "Disconnected from \(host), retrying"
        case .endedOnHost: return "Ended on \(host). Close the row to remove it"
        }
    }
}
