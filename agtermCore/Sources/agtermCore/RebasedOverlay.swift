import Foundation

public struct RebasedOverlay: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case starting, shown, failed(String)
    }

    public let id: UUID
    public let project: String
    public var state: State

    public init(project: String, state: State = .starting, id: UUID = UUID()) {
        self.id = id
        self.project = project
        self.state = state
    }
}

public enum RebasedOverlayOpenFailure: Equatable, Sendable {
    case unknownSession, alreadyOpen, presenter

    public var message: String {
        switch self {
        case .unknownSession: "no such session"
        case .alreadyOpen: "overlay already open"
        case .presenter: "a viewer presents this session: a Rebased overlay would open where nobody sees it"
        }
    }
}

@MainActor
public final class RebasedOverlayReleases {
    public static let shared = RebasedOverlayReleases()
    public var onRelease: ((UUID) -> Void)?

    func release(_ overlay: RebasedOverlay?) {
        guard let overlay else { return }
        onRelease?(overlay.id)
    }
}

extension AppStore {
    public func openRebasedOverlay(_ sessionID: UUID, overlay: RebasedOverlay, sizePercent: Int?) -> RebasedOverlayOpenFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        if presentationHub?.hasPresenter(session: sessionID) == true { return .presenter }
        if session.hudActive { closeOverlay(sessionID) }
        guard !session.overlayActive else { return .alreadyOpen }
        session.overlaySlotGeneration += 1
        session.overlayExitCode = nil
        session.remoteOverlays.clearFailure(nil)
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        session.overlayBackgroundColor = nil
        session.rebasedOverlay = overlay
        session.overlayActive = true
        return nil
    }
}
