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

    public init(project: String, state: State = .starting, diff: RebasedDiff? = nil, source: String? = nil,
                id: UUID = UUID(), view: RebasedViewRequest? = nil, onClose: RebasedOnClose? = nil) {
        self.id = id
        self.project = project
        self.state = state
        self.diff = diff
        self.source = source
        self.view = view
        self.onClose = onClose
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

    /// The pre-view four-field form, kept for `agtermCore`'s downstream consumers; the bridge refuses it.
    public func bridgeArgument(project: String) -> String {
        [base, head, mergeBase ? "1" : "0", project].joined(separator: "\t")
    }
}

/// ParkedRebased is a hidden session-wide IDE out of the slot, with the slot size it is seated back at.
public struct ParkedRebased: Equatable, Sendable {
    public var overlay: RebasedOverlay
    public let sizePercent: Int?
}

/// RebasedHideFailure is why `setRebasedHidden` changed nothing.
public enum RebasedHideFailure: Equatable, Sendable {
    case noOverlay
    case unpark(RebasedOverlayOpenFailure)

    public var message: String {
        switch self {
        case .noOverlay: "no Rebased overlay in this session"
        case .unpark(let failure): failure.message
        }
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
    /// onHiddenChange hears every hide or show of an IDE, whichever route flipped its slot bit or parked it:
    /// (session, overlay, hidden). The app moves the IDE window with it.
    public var onHiddenChange: ((UUID, UUID, Bool) -> Void)?

    func release(_ overlay: RebasedOverlay?) {
        guard let overlay else { return }
        onRelease?(overlay.id)
    }

    func hiddenChanged(_ session: Session, slot pane: OverlayPane?) {
        let overlay = pane.map { session.paneOverlay($0)?.rebased } ?? session.rebasedOverlay
        guard let overlay else { return }
        onHiddenChange?(session.id, overlay.id, session.overlayHidden(pane))
    }
}

extension AppStore {
    /// setRebasedHidden flips a pane IDE's slot bit; a session-wide IDE parks on hide and is seated back on
    /// show, which refuses while the slot is not free. Never acts on another occupant of the slot.
    @discardableResult
    public func setRebasedHidden(_ sessionID: UUID, id: UUID, _ hidden: Bool) -> RebasedHideFailure? {
        guard let session = session(withID: sessionID), let placement = session.rebasedPlacement,
              placement.overlay.id == id else { return .noOverlay }
        if let pane = placement.pane {
            setSlotHidden(session, slot: pane, hidden)
        } else if hidden {
            parkRebasedOverlay(session)
        } else if session.parkedRebased != nil {
            return unparkRebasedOverlay(session).map(RebasedHideFailure.unpark)
        }
        return nil
    }

    @discardableResult
    public func closeRebasedOverlay(_ sessionID: UUID, id: UUID) -> Bool {
        guard let session = session(withID: sessionID), let placement = session.rebasedPlacement,
              placement.overlay.id == id else { return false }
        if let pane = placement.pane { return closePaneOverlay(sessionID, pane: pane) }
        guard let parked = session.parkedRebased else { return closeOverlay(sessionID) }
        RebasedOverlayReleases.shared.release(parked.overlay)
        session.parkedRebased = nil
        scheduleTreeChanged()
        return true
    }

    public func sessionSlotFree(_ session: Session) -> Bool { sessionSlotRefusal(session) == nil }

    /// sessionSlotRefusal is why an IDE cannot be seated in the session-wide slot: a presenting viewer, or a
    /// program, page, IDE or remote job holding it. A HUD does not count; seating closes it.
    private func sessionSlotRefusal(_ session: Session) -> RebasedOverlayOpenFailure? {
        if presentationHub?.hasPresenter(session: session.id) == true { return .presenter }
        if session.coverOverlayActive || session.remoteOverlays.slot(nil) != nil { return .alreadyOpen }
        return nil
    }

    func parkRebasedOverlay(_ session: Session) {
        guard let overlay = session.rebasedOverlay else { return }
        session.parkedRebased = ParkedRebased(overlay: overlay, sizePercent: session.overlaySizePercent)
        // moved out first, so closing the slot releases nothing
        session.rebasedOverlay = nil
        closeOverlay(session.id)
        RebasedOverlayReleases.shared.onHiddenChange?(session.id, overlay.id, true)
    }

    func unparkRebasedOverlay(_ session: Session) -> RebasedOverlayOpenFailure? {
        guard let parked = session.parkedRebased else { return nil }
        if let refusal = sessionSlotRefusal(session) { return refusal }
        session.parkedRebased = nil
        seatRebasedOverlay(session, parked.overlay, sizePercent: parked.sizePercent)
        RebasedOverlayReleases.shared.onHiddenChange?(session.id, parked.overlay.id, false)
        return nil
    }

    // the caller has checked that nothing but a HUD holds the slot
    private func seatRebasedOverlay(_ session: Session, _ overlay: RebasedOverlay, sizePercent: Int?) {
        if session.hudActive { closeOverlay(session.id) }
        session.overlaySlotGeneration += 1
        session.overlayExitCode = nil
        session.remoteOverlays.clearFailure(nil)
        session.overlaySizePercent = sizePercent
        session.overlayBackgroundColor = nil
        session.rebasedOverlay = overlay
        session.overlayActive = true
        scheduleTreeChanged()
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
            scheduleTreeChanged()
            return nil
        }
        guard !session.coverOverlayActive else { return .alreadyOpen }
        seatRebasedOverlay(session, overlay, sizePercent: sizePercent.map { min(100, max(1, $0)) })
        return nil
    }
}
