/// Who receives a key event while a Rebased window may be key. agterm's menu is never swapped for IntelliJ's
/// (SwiftUI rewrites whatever main menu is installed), so a router hands IDE windows their keys ahead of it.
public struct RebasedMenuPolicy: Sendable {
    public enum KeyWindow: Sendable {
        case agterm, ide, other
    }

    public enum Route: Equatable, Sendable {
        case ide, agterm, toggle
    }

    /// Quit and Hide stay agterm's: the IDE's own exit is vetoed, so it would swallow them.
    public static let agtermChords: Set<Chord> = [Chord(mods: .command, key: "q"), Chord(mods: .command, key: "h")]

    public let toggle: RebasedKeyMatcher

    public init(keymap: Keymap) {
        toggle = RebasedKeyMatcher(keymap: keymap)
    }

    public func route(_ chord: Chord?, keyWindow: KeyWindow) -> Route {
        guard keyWindow == .ide else { return .agterm }
        guard let chord else { return .ide }
        if toggle.matches(chord) { return .toggle }
        return Self.agtermChords.contains(chord) ? .agterm : .ide
    }
}
