import Testing
@testable import agtermCore

struct RebasedMenuPolicyTests {
    private let policy = RebasedMenuPolicy(keymap: parseKeymap("map ctrl+shift+r rebased_toggle").keymap)

    @Test(arguments: [
        (Chord(mods: .command, key: "f"), RebasedMenuPolicy.Route.ide),
        (Chord(mods: .command, key: "w"), .ide),
        (Chord(mods: .control, key: "space"), .ide),
        (Chord(mods: .command, key: "q"), .agterm),
        (Chord(mods: .command, key: "h"), .agterm),
        (Chord(mods: [.control, .shift], key: "r"), .toggle),
    ])
    func anIDEKeyWindowGetsEveryKeyButQuitHideAndTheToggle(_ chord: Chord, _ expected: RebasedMenuPolicy.Route) {
        #expect(policy.route(chord, keyWindow: .ide) == expected)
    }

    @Test func aKeyWithNoChordStillGoesToTheIDE() {
        #expect(policy.route(nil, keyWindow: .ide) == .ide)
    }

    @Test(arguments: [RebasedMenuPolicy.KeyWindow.agterm, .other])
    func otherKeyWindowsRouteNothing(_ keyWindow: RebasedMenuPolicy.KeyWindow) {
        #expect(policy.route(Chord(mods: .command, key: "f"), keyWindow: keyWindow) == .agterm)
        #expect(policy.route(Chord(mods: [.control, .shift], key: "r"), keyWindow: keyWindow) == .agterm)
    }
}
