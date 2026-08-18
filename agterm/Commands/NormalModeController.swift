import Foundation
import agtermCore
import Observation

/// App-global normal mode: the host-free `NormalModeState` plus the observable mirrors the titlebar
/// indicator reads. One instance, because one keymap and one key monitor drive it.
///
/// The mode owns NO first responder. `CustomCommandRunner`'s app-wide monitor filters keys for it, feeds
/// every key in and owns the leader timeout; this only holds the state and republishes it.
/// `AppActions.perform(.normalMode)` is the single entry point — a bare Esc from the terminal must never
/// enter the mode, or Esc stops reaching vim, less and shell vi-mode. Leaving is Esc, the bare exit key, a
/// click in a pane, a focused text field, or the key window resigning key.
@MainActor
@Observable
final class NormalModeController {
    static let shared = NormalModeController()

    private(set) var isActive = false
    /// The half-typed leader's glyphs (`⌃␣ S`), empty with nothing armed.
    private(set) var armedGlyphs = ""

    @ObservationIgnored private var state = NormalModeState(binds: [])

    /// Whether a sequence is half-typed. The monitor reads it to decide whether focus leaving the terminal
    /// has a leader to drop.
    var isArmed: Bool { state.isArmed }

    /// Adopt a reloaded keymap. Leaves the mode OFF: the binds it was entered with are gone, and a silently
    /// rebound mode would keep swallowing keys against a map the user no longer has.
    func rebuild(binds: [NormalModeBind]) {
        state = NormalModeState(binds: binds)
        publish()
    }

    func enter() {
        state.enter()
        publish()
    }

    func exit() {
        state.exit()
        publish()
    }

    /// Abandon a half-typed sequence without leaving the mode (the leader timeout).
    func reset() {
        state.reset()
        publish()
    }

    func advance(_ chord: Chord) -> NormalModeState.Outcome {
        let outcome = state.advance(chord)
        publish()
        return outcome
    }

    func escape() -> NormalModeState.Outcome {
        let outcome = state.escape()
        publish()
        return outcome
    }

    /// Republish only on a real change: Observation notifies on every set, and an unchanged one per keystroke
    /// would re-render the indicator for keys the mode merely swallowed.
    private func publish() {
        if isActive != state.isActive {
            isActive = state.isActive
            NotificationCenter.default.post(name: .agtermNormalModeChanged, object: nil)
        }
        let glyphs = state.armedPrefix.glyphString
        if armedGlyphs != glyphs { armedGlyphs = glyphs }
    }
}
