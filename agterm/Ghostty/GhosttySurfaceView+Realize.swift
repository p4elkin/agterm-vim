import Foundation
import GhosttyKit

/// Releasing a hidden surface's GPU resources.
///
/// The eager deck keeps every session's surface mounted, and each one holds a renderer swap chain of three
/// frame states — a full-pane IOSurface render target plus its own font atlas textures per state. That is
/// roughly 130 MB per surface, live for as long as the session exists, whether or not it is on screen.
/// `ghostty_surface_set_occlusion` does not touch it: that only stops the display link.
///
/// `ghostty_surface_set_realized` comes from `patches/ghostty/0001-surface-realize-api.patch`, which exposes
/// the renderer's existing `displayRealized`/`displayUnrealized` through the C API. Unrealizing frees the
/// swap chain; realizing rebuilds it. The shell and terminal state are untouched, so a hidden session keeps
/// reading its pty and the first frame back shows everything that arrived meanwhile.
///
/// A hidden pane does NOT go blank while unrealized: `IOSurfaceLayer` only ever writes `layer.contents` in
/// its present callback and nothing clears it, so Core Animation keeps compositing the last frame. That is
/// also why one of the three targets per surface survives — the layer still holds it.
extension GhosttySurfaceView {
    /// How long a pane must stay hidden before its GPU resources are released.
    ///
    /// Unrealizing immediately would tear down and rebuild the swap chain on every transient cover — an
    /// overlay opening, the quick terminal, a glance at another session — which costs more than it saves and
    /// multiplies exposure to the teardown race in ghostty#13021. The memory that matters belongs to
    /// sessions parked for minutes or hours, so the delay loses nothing.
    static let unrealizeDelay: TimeInterval = 10

    /// Opt OUT with `AGTERM_SURFACE_UNREALIZE=0`. On by default: this fork carries the patch specifically to
    /// run it, and a surface that never unrealizes is the unpatched behavior.
    static let unrealizeEnabled = ProcessInfo.processInfo.environment["AGTERM_SURFACE_UNREALIZE"] != "0"

    /// React to this pane going on or off screen. Realizing is immediate — the pane is about to be looked
    /// at — while unrealizing waits out `unrealizeDelay`.
    func updateRealizeForVisibility() {
        guard Self.unrealizeEnabled else { return }
        realizeWorkItem?.cancel()
        realizeWorkItem = nil
        guard !deckVisible else {
            setRealized(true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.deckVisible else { return }
                self.setRealized(false)
            }
        }
        realizeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unrealizeDelay, execute: work)
    }

    /// Give up or reclaim this surface's GPU resources.
    ///
    /// Strictly alternating is the caller's job: libghostty asserts the swap chain is defunct on the way
    /// back in, so a doubled realize would panic a safe build. `realizeState` is what enforces that here,
    /// and the patch drops a repeated message on its side as a second line of defense.
    func setRealized(_ want: Bool) {
        guard Self.unrealizeEnabled else { return }
        // Before creation and after teardown there is no renderer to talk to.
        guard let surface, !isDestroyed else { return }
        guard want != realizeState else { return }
        realizeState = want
        ghostty_surface_set_realized(surface, want)
        // The rebuilt swap chain starts empty and only the terminal's own dirty tracking would refill it,
        // which a quiet session does not trigger. Without this the pane keeps showing the pre-unrealize
        // frame indefinitely — stale rather than blank, since the layer never dropped its contents.
        if want { ghostty_surface_refresh(surface) }
    }

    /// Stop a scheduled unrealize. Called from `destroySurface`, so a pending work item cannot fire against
    /// a freed surface — `setRealized`'s own guard covers it too, but a cancelled timer is cheaper than a
    /// closure that wakes up to do nothing.
    func cancelPendingRealizeWork() {
        realizeWorkItem?.cancel()
        realizeWorkItem = nil
    }
}
