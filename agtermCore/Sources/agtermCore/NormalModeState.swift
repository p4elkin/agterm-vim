import Foundation

/// Normal mode: on/off plus a `KeybindMatcher` over the `nmap` binds.
///
/// While the mode is on nothing reaches the terminal, so a chord matching no bind is SWALLOWED — the one
/// behavioral difference from the global monitor, whose unmatched chords pass through. Entering is the app's
/// job (the `normal_mode` built-in); leaving is Esc or the bare `normalModeExitKey`. Deadline-free: the
/// app-side leader timeout calls `reset()`.
public struct NormalModeState: Sendable {
    /// What the caller does with the key it just fed in.
    public enum Outcome: Equatable, Sendable {
        case fired(BuiltinAction)
        /// A custom command by id, the `nmap "<name>"` form. Separate from `fired` because the caller spawns
        /// a process for it and must skip OS key repeats the mode otherwise honors.
        case firedCommand(UUID)
        case armed
        /// Consumed with nothing to do: an unmatched chord, or Esc abandoning an armed leader.
        case swallowed
        case exited
        /// The mode is off, so the key belongs to whoever asked. The only outcome that passes through.
        case inactive
    }

    private var matcher: KeybindMatcher
    public private(set) var isActive = false

    public init(binds: [NormalModeBind]) {
        matcher = KeybindMatcher(binds.map { ($0.keybind, $0.target) })
    }

    /// Whether a sequence is half-typed. Gates the app-side leader timeout.
    public var isArmed: Bool { matcher.isArmed }

    /// The chords of a half-typed sequence, for the mode indicator.
    public var armedPrefix: Keybind { matcher.pendingPrefix }

    public mutating func enter() {
        isActive = true
        matcher.reset()
    }

    public mutating func exit() {
        isActive = false
        matcher.reset()
    }

    /// Abandon a half-typed sequence without leaving the mode (the app-side leader timeout).
    public mutating func reset() {
        matcher.reset()
    }

    public mutating func advance(_ chord: Chord) -> Outcome {
        guard isActive else { return .inactive }

        // the exit key is bindable as a sequence tail, so it only leaves the mode with no leader armed.
        if !matcher.isArmed, chord.mods.isEmpty, chord.key == normalModeExitKey {
            exit()
            return .exited
        }

        switch matcher.advance(chord) {
        case .fired(.builtin(let action)):
            return .fired(action)
        case .fired(.command(let id)):
            return .firedCommand(id)
        case .armed:
            return .armed
        case .unmatched:
            return .swallowed
        }
    }

    /// Esc abandons an armed leader but stays in the mode; with nothing armed it leaves. Mirrors the global
    /// monitor's Esc rule.
    public mutating func escape() -> Outcome {
        guard isActive else { return .inactive }
        guard !matcher.isArmed else {
            matcher.reset()
            return .swallowed
        }
        exit()
        return .exited
    }
}
