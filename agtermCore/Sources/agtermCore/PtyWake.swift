import Foundation

/// PtyWake is which pane of a row asleep here a control command drives: a command that acts on the pane's live surface
/// wakes the row first and waits for that pane to attach, and `session.text` reads the pane's screen on the origin.
public enum PtyWake {
    /// commands act on a pane's live surface. `session.restart` is not one: an attached row forwards it to the origin.
    public static let commands: Set<Command> = [
        .sessionType, .sessionPaste, .sessionSelectAll, .sessionCopy, .sessionSearch, .sessionLead,
        .fontInc, .fontDec, .fontReset, .surfaceCursor,
    ]

    /// Pane is the addressed pane and the identity its lead reports arrive under.
    public struct Pane: Equatable, Sendable {
        public let role: StatusPane
        public let identity: UUID

        public init(role: StatusPane, identity: UUID) {
            self.role = role
            self.identity = identity
        }
    }

    /// pane is the pane `request` drives on asleep `session`; nil leaves the command to answer in its own words: an
    /// awake row, the scratch (a sleep keeps it), a missing split, or arguments the command refuses. A hidden split no
    /// sleep released has no surface awake either, so only `session.text`, which needs none, addresses it.
    /// `surface` is a `surface.cursor` target's kind, which the caller resolves.
    @MainActor
    public static func pane(of request: ControlRequest, on session: Session, surface: TerminalZoomSurface? = nil) -> Pane? {
        guard session.asleep else { return nil }
        let args = request.args
        let focused: StatusPane = session.focusedPane == .right ? .right : .left
        let role: StatusPane?
        switch request.cmd {
        case .sessionType:
            guard let text = args?.text, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
            role = named(args, on: session, token: true, unnamed: .left)
        case .sessionText:
            role = named(args, on: session, token: true, unnamed: focused)
        case .sessionPaste, .sessionLead, .fontInc, .fontDec, .fontReset:
            role = named(args, on: session, token: false, unnamed: .left)
        case .sessionSelectAll, .sessionCopy:
            role = .left
        case .sessionSearch:
            guard args?.to == nil || ["next", "prev"].contains(args?.to) else { return nil }
            role = focused
        case .surfaceCursor:
            if let token = args?.paneID, !token.isEmpty {
                role = tokenRole(token, on: session)
            } else {
                role = surface == .primary ? .left : (surface == .split ? .right : nil)
            }
        default:
            return nil
        }
        switch role {
        case .left: return Pane(role: .left, identity: session.paneIdentity)
        case .right:
            guard session.hasSplit, request.cmd == .sessionText || session.isSplit || session.rightPaneExists else { return nil }
            return session.splitPaneIdentity.map { Pane(role: .right, identity: $0) }
        case .scratch, nil: return nil
        }
    }

    /// named reads `--pane` and `--pane-id` as `Session.paneAddress` does; nil for a spelling or token the command refuses.
    @MainActor
    private static func named(_ args: ControlArgs?, on session: Session, token: Bool, unnamed: StatusPane) -> StatusPane? {
        var role: StatusPane?
        if let raw = args?.pane {
            guard let parsed = StatusPane(controlName: raw) else { return nil }
            role = parsed
        }
        if token, let id = args?.paneID, !id.isEmpty {
            return tokenRole(id, on: session) ?? role
        }
        return role ?? unnamed
    }

    /// tokenRole resolves a pane token on a row whose released panes have no surface to carry it.
    @MainActor
    private static func tokenRole(_ token: String, on session: Session) -> StatusPane? {
        if let role = session.paneRole(forToken: token) { return role }
        if token == session.paneIdentity.uuidString { return .left }
        return token == session.splitPaneIdentity?.uuidString ? .right : nil
    }
}
