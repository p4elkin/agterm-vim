import Testing
@testable import agtermCore

struct TurnMarkTests {
    @Test func lineCarriesTheNeedleForThatTurn() {
        #expect(TurnMark.line(for: 7).contains(TurnMark.needle(for: 7)))
    }

    @Test func lineCarriesTheNeedleForEveryTurnItIsAskedFor() {
        for turn in [0, 1, 9, 10, 99, 100, 1234] {
            #expect(TurnMark.line(for: turn).contains(TurnMark.needle(for: turn)))
        }
    }

    @Test func consecutiveTurnsGetDifferentNeedles() {
        #expect(TurnMark.needle(for: 7) != TurnMark.needle(for: 8))
    }

    /// The whole point of the brackets: searching for turn 1 must not land on turn 10 or 100.
    @Test func aShorterNeedleIsNotContainedInALongerOne() {
        #expect(!TurnMark.needle(for: 10).contains(TurnMark.needle(for: 1)))
        #expect(!TurnMark.needle(for: 100).contains(TurnMark.needle(for: 10)))
        #expect(!TurnMark.needle(for: 123).contains(TurnMark.needle(for: 12)))
        #expect(!TurnMark.needle(for: 123).contains(TurnMark.needle(for: 23)))
    }

    @Test func aShorterNeedleIsNotFoundInALongerTurnsLine() {
        #expect(!TurnMark.line(for: 10).contains(TurnMark.needle(for: 1)))
        #expect(!TurnMark.line(for: 100).contains(TurnMark.needle(for: 10)))
    }

    @Test func theNeedleAvoidsCharactersAnAgentTypesByAccident() {
        let needle = TurnMark.needle(for: 3)
        #expect(needle.contains("⟦"))
        #expect(needle.contains("⟧"))
        #expect(!needle.lowercased().contains("turn"))
    }

    @Test func theLineIsASingleLine() {
        #expect(!TurnMark.line(for: 42).contains("\n"))
        #expect(!TurnMark.line(for: 42).contains("\r"))
    }

    @Test func thePayloadCarriesTheLineAndTheNeedle() {
        let payload = TurnMark.payload(for: 42)
        #expect(payload.contains(TurnMark.line(for: 42)))
        #expect(payload.contains(TurnMark.needle(for: 42)))
    }

    /// A raw-mode pty does no newline translation, so the payload has to return the carriage itself.
    @Test func thePayloadOpensWithABlankLineAndEndsWithACarriageReturnAndNewline() {
        let payload = TurnMark.payload(for: 5)
        #expect(payload.hasPrefix("\r\n\r\n"))
        #expect(payload.hasSuffix("\r\n"))
    }

    @Test func negativeTurnsStillProduceAUniqueNeedle() {
        #expect(TurnMark.needle(for: -1) != TurnMark.needle(for: 1))
        #expect(TurnMark.line(for: -1).contains(TurnMark.needle(for: -1)))
    }
}
