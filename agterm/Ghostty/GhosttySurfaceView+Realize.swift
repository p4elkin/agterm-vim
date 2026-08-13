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
extension GhosttySurfaceView {
    /// Whether unrealizing is on. Spike gate: the round trip has never run against the Metal backend
    /// upstream — only GTK/OpenGL — so it stays opt-in until measured on a real workspace.
    static let unrealizeEnabled = ProcessInfo.processInfo.environment["AGTERM_SURFACE_UNREALIZE"] == "1"

    /// Give up or reclaim this surface's GPU resources.
    ///
    /// Strictly alternating is the caller's job: libghostty asserts the swap chain is defunct on the way
    /// back in, so a doubled realize would panic a safe build. `realizeState` is what enforces that here,
    /// and the patch drops a repeated message on its side as a second line of defense.
    func setRealized(_ want: Bool) {
        guard Self.unrealizeEnabled else { return }
        // Before creation and after teardown there is no renderer to talk to. A surface created while
        // already hidden starts realized, and the first hide unrealizes it.
        guard let surface, !isDestroyed else { return }
        guard want != realizeState else { return }
        realizeState = want
        ghostty_surface_set_realized(surface, want)
        // The rebuilt swap chain starts empty and only the terminal's own dirty tracking would refill it,
        // which a quiet session does not trigger. Without this the pane returns blank over a live buffer —
        // the same reason `updateMetalLayerSize` refreshes after a re-parent.
        if want { ghostty_surface_refresh(surface) }
    }
}
