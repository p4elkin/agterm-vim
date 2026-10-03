import agtermCore

public enum HeadlessSupport: Equatable, Sendable {
    case served
    /// Answered by the presenting Mac.
    case forwarded
    /// Served, booked as a job or forwarded, per request.
    case routed
    case refused(String)
}

/// `ForwardPolicy` with the refusal text the origin answers.
public enum HeadlessCatalog {
    public static func support(for command: Command) -> HeadlessSupport {
        switch ForwardPolicy.kind(of: command) {
        case .served: return .served
        case .forwarded: return .forwarded
        case .routed: return .routed
        case .refused(let reason): return .refused(refusal(command, reason))
        }
    }

    public static func refusal(_ command: Command, _ reason: String) -> String {
        "\(command.rawValue) is not available on a headless origin: \(reason)"
    }
}
