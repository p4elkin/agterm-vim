import Testing
@testable import agtermCore

struct RebasedKeyMatcherTests {
    private func matcher(_ text: String) -> RebasedKeyMatcher { RebasedKeyMatcher(keymap: parseKeymap(text).keymap) }

    @Test func aDirectMapChordMatches() {
        #expect(matcher("map ctrl+shift+r rebased_toggle").matches(Chord(mods: [.control, .shift], key: "r")))
    }

    @Test func aSecondDirectChordMatchesToo() {
        let both = matcher("map ctrl+shift+r|cmd+shift+y rebased_toggle")
        #expect(both.matches(Chord(mods: [.control, .shift], key: "r")))
        #expect(both.matches(Chord(mods: [.command, .shift], key: "y")))
    }

    @Test func withNoMapLineNothingMatches() {
        #expect(matcher("").chords.isEmpty)
    }

    @Test func aLeaderSequenceDoesNotMatch() {
        let leader = matcher("map ctrl+space>r rebased_toggle")
        #expect(leader.chords.isEmpty)
        #expect(!leader.matches(Chord(mods: .control, key: "space")))
    }

    @Test func anUnboundKeyPassesThrough() {
        #expect(!matcher("map ctrl+shift+r rebased_toggle").matches(Chord(mods: .command, key: "f")))
    }
}
