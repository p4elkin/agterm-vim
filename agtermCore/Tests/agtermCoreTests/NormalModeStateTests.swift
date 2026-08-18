import Foundation
import Testing
@testable import agtermCore

struct NormalModeStateTests {
    private let space = Chord(mods: [], key: "space")
    private let s = Chord(mods: [], key: "s")
    private let d = Chord(mods: [], key: "d")
    private let i = Chord(mods: [], key: normalModeExitKey)
    private let ctrlI = Chord(mods: .control, key: normalModeExitKey)

    private func state(_ binds: [NormalModeBind] = []) -> NormalModeState {
        var state = NormalModeState(binds: binds)
        state.enter()
        return state
    }

    @Test func startsInactiveAndPassesKeysThrough() {
        var mode = NormalModeState(binds: [NormalModeBind(keybind: [d], target: .builtin(.toggleSplit))])
        #expect(!mode.isActive)
        #expect(mode.advance(d) == .inactive)
        #expect(mode.escape() == .inactive)
    }

    @Test func enterActivates() {
        var mode = NormalModeState(binds: [])
        mode.enter()
        #expect(mode.isActive)
        #expect(!mode.isArmed)
    }

    @Test func singleKeyFires() {
        var mode = state([NormalModeBind(keybind: [d], target: .builtin(.toggleSplit))])
        #expect(mode.advance(d) == .fired(.toggleSplit))
        #expect(mode.isActive)
    }

    @Test func aPaneCreatingActionFiresAndLeavesTheMode() {
        let n = Chord(mods: [], key: "n")
        var mode = state([NormalModeBind(keybind: [n], target: .builtin(.newSession))])
        #expect(mode.advance(n) == .fired(.newSession))
        #expect(!mode.isActive)
    }

    @Test func aPaneCreatingActionLeavesTheModeFromASequenceToo() {
        var mode = state([NormalModeBind(keybind: [space, Chord(mods: [], key: "n")], target: .builtin(.newSession))])
        #expect(mode.advance(space) == .armed)
        #expect(mode.advance(Chord(mods: [], key: "n")) == .fired(.newSession))
        #expect(!mode.isActive)
        #expect(!mode.isArmed)
    }

    @Test func sequenceFires() {
        var mode = state([NormalModeBind(keybind: [space, s], target: .builtin(.toggleSidebar))])
        #expect(mode.advance(space) == .armed)
        #expect(mode.isArmed)
        #expect(mode.advance(s) == .fired(.toggleSidebar))
        #expect(!mode.isArmed)
    }

    @Test func armedPrefixExposesTypedChords() {
        var mode = state([NormalModeBind(keybind: [space, s], target: .builtin(.toggleSidebar))])
        #expect(mode.armedPrefix.isEmpty)
        _ = mode.advance(space)
        #expect(mode.armedPrefix == [space])
        _ = mode.advance(s)
        #expect(mode.armedPrefix.isEmpty)
    }

    @Test func unmatchedKeyIsSwallowed() {
        var mode = state([NormalModeBind(keybind: [d], target: .builtin(.toggleSplit))])
        #expect(mode.advance(s) == .swallowed)
        #expect(mode.isActive)
    }

    @Test func unmatchedSequenceTailIsSwallowed() {
        var mode = state([NormalModeBind(keybind: [space, s], target: .builtin(.toggleSidebar))])
        #expect(mode.advance(space) == .armed)
        #expect(mode.advance(d) == .swallowed)
        #expect(!mode.isArmed)
        #expect(mode.isActive)
    }

    @Test func exitKeyLeavesMode() {
        var mode = state([NormalModeBind(keybind: [d], target: .builtin(.toggleSplit))])
        #expect(mode.advance(i) == .exited)
        #expect(!mode.isActive)
        #expect(mode.advance(d) == .inactive)
    }

    @Test func exitKeyBindsAsSequenceTail() {
        var mode = state([NormalModeBind(keybind: [space, i], target: .builtin(.toggleSidebar))])
        #expect(mode.advance(space) == .armed)
        #expect(mode.advance(i) == .fired(.toggleSidebar))
        #expect(mode.isActive)
    }

    @Test func modifiedExitKeyDoesNotLeave() {
        var mode = state([NormalModeBind(keybind: [ctrlI], target: .builtin(.toggleSplit))])
        #expect(mode.advance(ctrlI) == .fired(.toggleSplit))
        #expect(mode.isActive)
    }

    @Test func escapeLeavesModeWhenNothingArmed() {
        var mode = state([NormalModeBind(keybind: [d], target: .builtin(.toggleSplit))])
        #expect(mode.escape() == .exited)
        #expect(!mode.isActive)
    }

    @Test func escapeAbandonsArmedLeaderWithoutLeaving() {
        var mode = state([NormalModeBind(keybind: [space, s], target: .builtin(.toggleSidebar))])
        #expect(mode.advance(space) == .armed)
        #expect(mode.escape() == .swallowed)
        #expect(!mode.isArmed)
        #expect(mode.isActive)
        #expect(mode.escape() == .exited)
    }

    @Test func resetClearsArmedLeaderKeepingMode() {
        var mode = state([NormalModeBind(keybind: [space, s], target: .builtin(.toggleSidebar))])
        #expect(mode.advance(space) == .armed)
        mode.reset()
        #expect(!mode.isArmed)
        #expect(mode.isActive)
        #expect(mode.advance(s) == .swallowed)
    }

    @Test func reenteringClearsAStaleLeader() {
        var mode = state([NormalModeBind(keybind: [space, s], target: .builtin(.toggleSidebar))])
        #expect(mode.advance(space) == .armed)
        mode.exit()
        mode.enter()
        #expect(!mode.isArmed)
        #expect(mode.advance(s) == .swallowed)
    }

    @Test func singleKeyFiresACommandTarget() {
        let id = UUID()
        var mode = state([NormalModeBind(keybind: [d], target: .command(id))])
        #expect(mode.advance(d) == .firedCommand(id))
        #expect(mode.isActive)
    }

    @Test func sequenceEndingInACommandArmsThenFires() {
        let id = UUID()
        var mode = state([NormalModeBind(keybind: [space, s], target: .command(id))])
        #expect(mode.advance(space) == .armed)
        #expect(mode.advance(s) == .firedCommand(id))
        #expect(!mode.isArmed)
        #expect(mode.advance(i) == .exited)
    }

    @Test func prefixConflictKeepsTheEarlierBindAndNamesItsCommandTarget() {
        let command = CustomCommand(name: "Annotate last response", command: "annotate", shortcut: "")
        let parsed = [
            ParsedNormalBind(keybind: [space], target: .commandName(command.name), line: 3),
            ParsedNormalBind(keybind: [space, s], target: .builtin(.toggleSidebar), line: 4)
        ]
        var diagnostics: [KeymapDiagnostic] = []
        let kept = resolveNormalModeBinds(parsed, commands: [command], diagnostics: &diagnostics)
        #expect(kept == [NormalModeBind(keybind: [space], target: .command(command.id))])
        #expect(diagnostics == [KeymapDiagnostic(
            line: 4,
            message: "normal-mode keybind conflicts with command \"Annotate last response\"; nmap skipped")])
    }
}
