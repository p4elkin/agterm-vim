import Foundation

public struct RebasedOverlay: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// A remote row's repository is being mirrored to this Mac; `project` is still the host's path.
        case fetching, starting, shown, failed(String)
    }

    public let id: UUID
    public var project: String
    public var state: State
    /// The range last asked for with `--diff`; the bridge shows it once the frame is on screen.
    public var diff: RebasedDiff?
    /// `host:path` of the repository a remote row's `project` mirrors, nil on a local row.
    public var source: String?
    public var view: RebasedViewRequest?
    public var onClose: RebasedOnClose?
    public var hidden: Bool

    public init(project: String, state: State = .starting, diff: RebasedDiff? = nil, source: String? = nil,
                id: UUID = UUID(), view: RebasedViewRequest? = nil, onClose: RebasedOnClose? = nil, hidden: Bool = false) {
        self.id = id
        self.project = project
        self.state = state
        self.diff = diff
        self.source = source
        self.view = view
        self.onClose = onClose
        self.hidden = hidden
    }
}

/// A `--diff` range in git's spelling: `A..B`, `A...B` (from the merge base), or `A` for `A..HEAD`; an
/// empty side is `HEAD`. The sides reach git as arguments, so one git would read as an option is refused.
public struct RebasedDiff: Equatable, Sendable {
    public let base: String
    public let head: String
    public let mergeBase: Bool

    public init(base: String, head: String, mergeBase: Bool) {
        self.base = base
        self.head = head
        self.mergeBase = mergeBase
    }

    public init?(spec: String) {
        let separator = spec.contains("...") ? "..." : ".."
        let sides = spec.components(separatedBy: separator)
        guard sides.count <= 2, sides.contains(where: { !$0.isEmpty }) else { return nil }
        let base = sides[0].isEmpty ? "HEAD" : sides[0]
        let head = sides.count == 2 && !sides[1].isEmpty ? sides[1] : "HEAD"
        guard Self.isRevision(base), Self.isRevision(head) else { return nil }
        self.init(base: base, head: head, mergeBase: separator == "...")
    }

    private static func isRevision(_ side: String) -> Bool {
        guard let first = side.first, first != "-", first != "." else { return false }
        let banned = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return !side.contains("..") && !side.unicodeScalars.contains(where: banned.contains)
    }

    public var spec: String { base + (mergeBase ? "..." : "..") + head }

    /// The bridge's `diff` argument: tab-separated, the project last because a path may hold a tab.
    public func bridgeArgument(request: String, workingTree: Bool, pane: Bool, project: String) -> String {
        [request, base, head, mergeBase ? "1" : "0", workingTree ? "1" : "0", pane ? "pane" : "session", project].joined(separator: "\t")
    }

    public func bridgeArgument(project: String) -> String {
        [base, head, mergeBase ? "1" : "0", project].joined(separator: "\t")
    }
}

public enum RebasedOverlayOpenFailure: Equatable, Sendable {
    case unknownSession, alreadyOpen, paneNotVisible, presenter

    public var message: String { message(pane: nil) }

    public func message(pane: OverlayPane?) -> String {
        switch self {
        case .unknownSession: "no such session"
        case .alreadyOpen: pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen
        case .paneNotVisible: PaneOverlayError.paneNotVisible
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
    @discardableResult
    public func setRebasedHidden(_ sessionID: UUID, id: UUID, _ hidden: Bool) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        return session.updateRebasedOverlay(id) { $0.hidden = hidden }
    }

    @discardableResult
    public func closeRebasedOverlay(_ sessionID: UUID, id: UUID) -> Bool {
        guard let session = session(withID: sessionID), let placement = session.rebasedPlacement,
              placement.overlay.id == id else { return false }
        if let pane = placement.pane { return closePaneOverlay(sessionID, pane: pane) }
        return closeOverlay(sessionID)
    }

    public func openRebasedOverlay(_ sessionID: UUID, overlay: RebasedOverlay, sizePercent: Int?,
                                   pane: OverlayPane? = nil) -> RebasedOverlayOpenFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        if presentationHub?.hasPresenter(session: sessionID) == true { return .presenter }
        guard session.rebasedPlacement == nil else { return .alreadyOpen }
        if let pane {
            guard session.paneOverlay(pane) == nil else { return .alreadyOpen }
            guard session.rendersPane(pane) else { return .paneNotVisible }
            discardOrphanPaneOverlaySurface(session, pane: pane)
            session.setPaneOverlayExitCode(nil, pane: pane)
            session.remoteOverlays.clearFailure(pane)
            session.mintPaneOverlayGeneration(pane)
            session.setPaneOverlay(PaneOverlay(rebased: overlay), pane: pane)
            return nil
        }
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
