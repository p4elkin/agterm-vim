import AppKit
import agtermCore

extension agtermApp {
    /// The wake renewal: fresh attach lines and the origin scratch, then the unshown pane of a hidden split, which existed
    /// before the sleep. The deck mounts only the shown pane, while `leadsHere`, `addressableSurface`, `tree` and a
    /// `--pane` command read the other one too.
    @MainActor
    static func wakeRenewal(server: ControlServer?, services: SurfaceServices,
                            env: @escaping @MainActor (Session, StatusPane) -> [String: String]) -> @MainActor (Session) -> Void {
        { [weak server] session in
            server?.wakeAttachLines(for: session)
            guard session.hasSplit, !session.isSplit, let store = services.library.store(forSession: session.id) else { return }
            if session.splitFocused, session.surface == nil {
                session.surface = offDeck(makeSurface(for: session, store: store, env: env(session, .left), services: services))
            } else if !session.splitFocused, session.splitSurface == nil, session.rightPaneExists {
                session.splitSurface = offDeck(makeSplitSurface(for: session, store: store, env: env(session, .right),
                                                                services: services))
            }
        }
    }

    // libghostty creates a surface for a view outside any window; the deck reparents it once the pane is shown
    @MainActor
    private static func offDeck(_ view: GhosttySurfaceView) -> GhosttySurfaceView {
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.createSurface()
        return view
    }
}
