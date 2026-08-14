import Foundation
import Testing
@testable import agtermCore

struct KeybindMatcherTests {
    private let ctrlA = Chord(mods: .control, key: "a")
    private let b = Chord(mods: [], key: "b")
    private let c = Chord(mods: [], key: "c")
    private let cmdShiftU = Chord(mods: [.command, .shift], key: "u")

    @Test func simpleChordFires() {
        let target = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([cmdShiftU], target)])
        #expect(matcher.advance(cmdShiftU) == .fired(target))
        #expect(!matcher.isArmed)
    }

    @Test func unmatchedSingleChord() {
        let target = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([cmdShiftU], target)])
        #expect(matcher.advance(ctrlA) == .unmatched)
        #expect(!matcher.isArmed)
    }

    @Test func sequenceFiresOnSecondChord() {
        let target = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([ctrlA, b], target)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.isArmed)
        #expect(matcher.advance(b) == .fired(target))
        #expect(!matcher.isArmed)
    }

    @Test func wrongSecondChordResetsAndUnmatches() {
        let target = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([ctrlA, b], target)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(c) == .unmatched)
        #expect(!matcher.isArmed)
        #expect(matcher.advance(ctrlA) == .armed)
    }

    @Test func resetClearsPending() {
        let target = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([ctrlA, b], target)])
        #expect(matcher.advance(ctrlA) == .armed)
        matcher.reset()
        #expect(!matcher.isArmed)
        #expect(matcher.advance(b) == .unmatched)
    }

    @Test func twoSequencesSharingLeader() {
        let targetB = KeybindTarget.command(UUID())
        let targetC = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([ctrlA, b], targetB), ([ctrlA, c], targetC)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(b) == .fired(targetB))

        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(c) == .fired(targetC))
    }

    @Test func simpleAndSequenceCoexist() {
        let simpleTarget = KeybindTarget.command(UUID())
        let sequenceTarget = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([cmdShiftU], simpleTarget), ([ctrlA, b], sequenceTarget)])
        #expect(matcher.advance(cmdShiftU) == .fired(simpleTarget))
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(b) == .fired(sequenceTarget))
    }

    @Test func rePressingLeaderWhileArmedReArms() {
        let target = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([ctrlA, b], target)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.isArmed)
        #expect(matcher.advance(b) == .fired(target))
    }

    @Test func wrongChordWhileArmedThatIsItselfASimpleBindFires() {
        let sequenceTarget = KeybindTarget.command(UUID())
        let simpleTarget = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([ctrlA, b], sequenceTarget), ([cmdShiftU], simpleTarget)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(cmdShiftU) == .fired(simpleTarget))
        #expect(!matcher.isArmed)
    }

    @Test func alternativesShareOneTarget() {
        let target = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([cmdShiftU], target), ([ctrlA, b], target)])
        #expect(matcher.advance(cmdShiftU) == .fired(target))
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(b) == .fired(target))
    }

    @Test func builtinAndCommandTargetsCoexist() {
        let command = KeybindTarget.command(UUID())
        let builtin = KeybindTarget.builtin(.toggleSplit)
        var matcher = KeybindMatcher([([cmdShiftU], command), ([ctrlA, b], builtin)])
        #expect(matcher.advance(cmdShiftU) == .fired(command))
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(b) == .fired(builtin))
    }

    @Test func emptyMatcherUnmatches() {
        var matcher = KeybindMatcher([])
        #expect(matcher.advance(ctrlA) == .unmatched)
        #expect(!matcher.isArmed)
    }

    @Test func matcherFiresCustomAndBuiltinTargets() {
        let id = UUID()
        var matcher = KeybindMatcher([([cmdShiftU], .command(id)), ([ctrlA, b], .builtin(.toggleSplit))])
        #expect(matcher.advance(cmdShiftU) == .fired(.command(id)))
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(b) == .fired(.builtin(.toggleSplit)))
    }

    @Test func lastFiredKeybindIsNilBeforeAnythingFires() {
        let matcher = KeybindMatcher([([cmdShiftU], .command(UUID()))])
        #expect(matcher.lastFiredKeybind == nil)
    }

    @Test func lastFiredKeybindRecordsASingleChordBind() {
        var matcher = KeybindMatcher([([cmdShiftU], .command(UUID()))])
        _ = matcher.advance(cmdShiftU)
        #expect(matcher.lastFiredKeybind == [cmdShiftU])
    }

    @Test func lastFiredKeybindRecordsAWholeSequence() {
        var matcher = KeybindMatcher([([ctrlA, b], .command(UUID()))])
        _ = matcher.advance(ctrlA)
        _ = matcher.advance(b)
        #expect(matcher.lastFiredKeybind == [ctrlA, b])
    }

    @Test func lastFiredKeybindOnTheReArmPathIsTheFreshChordAlone() {
        let simpleTarget = KeybindTarget.command(UUID())
        var matcher = KeybindMatcher([([ctrlA, b], .command(UUID())), ([cmdShiftU], simpleTarget)])
        _ = matcher.advance(ctrlA)
        #expect(matcher.advance(cmdShiftU) == .fired(simpleTarget))
        #expect(matcher.lastFiredKeybind == [cmdShiftU])
    }

    @Test func armedAndUnmatchedLeaveLastFiredKeybindAlone() {
        var matcher = KeybindMatcher([([cmdShiftU], .command(UUID())), ([ctrlA, b], .command(UUID()))])
        _ = matcher.advance(cmdShiftU)
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.lastFiredKeybind == [cmdShiftU])
        #expect(matcher.advance(c) == .unmatched)
        #expect(matcher.lastFiredKeybind == [cmdShiftU])
    }

    @Test func twoBindsSharingATargetAreToldApartByLastFiredKeybind() {
        let target = KeybindTarget.builtin(.toggleSplit)
        var matcher = KeybindMatcher([([cmdShiftU], target), ([ctrlA, b], target)])
        _ = matcher.advance(cmdShiftU)
        #expect(matcher.lastFiredKeybind == [cmdShiftU])
        _ = matcher.advance(ctrlA)
        _ = matcher.advance(b)
        #expect(matcher.lastFiredKeybind == [ctrlA, b])
    }

    @Test func exactCustomMatchWinsOverBuiltinSequencePrefix() {
        let id = UUID()
        var matcher = KeybindMatcher([([ctrlA], .command(id)), ([ctrlA, b], .builtin(.toggleSplit))])
        #expect(matcher.advance(ctrlA) == .fired(.command(id)))
        #expect(!matcher.isArmed)
    }
}
