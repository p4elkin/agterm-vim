/// The chords that toggle a Rebased overlay while an IDE window is key: the action's menu chord and any
/// single-chord alternative. A leader sequence never matches there, since its leader (⌃Space by default) is
/// IntelliJ's code completion.
public struct RebasedKeyMatcher: Equatable, Sendable {
    public let chords: Set<Chord>

    public init(keymap: Keymap) {
        let alternatives = keymap.sequences(for: .rebasedToggle).filter { $0.count == 1 }.map { $0[0] }
        chords = Set((keymap.equivalent(for: .rebasedToggle).map { [$0] } ?? []) + alternatives)
    }

    public func matches(_ chord: Chord) -> Bool { chords.contains(chord) }
}
