import Foundation

/// Whether normal mode has yielded the keyboard to a program overlay.
///
/// The question is an event, not a state: the mode yields only to an overlay that APPEARED on the keyboard
/// target it saw at the previous key. Walking onto a session or pane whose overlay is already running is an
/// arrival and keeps the keys, so `j`/`k` carry past it. `step` advances the memory, so it must be called
/// exactly once per key event.
public struct NormalModeOverlayHandover: Sendable {
    private struct Target: Equatable {
        let session: UUID?
        let pane: OverlayPane
    }

    private var last: Target?
    private var lastOwned = false
    public private(set) var isYielded = false

    public init() {}

    /// Forget the remembered target. The next key then reads as an arrival, which is what makes entering the
    /// mode over a running overlay take the keyboard.
    public mutating func reset() {
        last = nil
        lastOwned = false
        isYielded = false
    }

    @discardableResult
    public mutating func step(session: UUID?, pane: OverlayPane, ownsKeyboard: Bool) -> Bool {
        let target = Target(session: session, pane: pane)
        if !ownsKeyboard {
            isYielded = false
        } else if target != last {
            isYielded = false
        } else if !lastOwned {
            isYielded = true
        }
        // the remaining case — same target, overlaid at the previous key too — carries `isYielded` unchanged.
        last = target
        lastOwned = ownsKeyboard
        return isYielded
    }
}
