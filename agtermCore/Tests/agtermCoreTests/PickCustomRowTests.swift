import Testing
@testable import agtermCore

struct PickCustomRowTests {
    @Test func emptyQueryDoesNotOfferCustomRow() {
        #expect(pickCustomRowLabel(query: "", titles: [], allowCustom: true) == nil)
        #expect(pickCustomRowLabel(query: " \t ", titles: [], allowCustom: true) == nil)
    }

    @Test func unmatchedQueryOffersCustomRowWhenAllowed() {
        #expect(pickCustomRowLabel(query: "new value", titles: [], allowCustom: true)
            == "Use \"new value\"")
    }

    @Test func unmatchedQueryDoesNotOfferCustomRowWhenDisallowed() {
        #expect(pickCustomRowLabel(query: "new value", titles: [], allowCustom: false) == nil)
    }

    @Test func matchingQueryDoesNotOfferCustomRow() {
        #expect(pickCustomRowLabel(query: "one", titles: ["one"], allowCustom: true) == nil)
    }

    @Test func customVerbReplacesTheDefaultOne() {
        #expect(pickCustomRowLabel(query: "foo", titles: [], allowCustom: true, verb: "Create workspace")
            == "Create workspace \"foo\"")
    }

    @Test func customVerbStillRejectsBlankQuery() {
        #expect(pickCustomRowLabel(query: "", titles: [], allowCustom: true, verb: "Create workspace") == nil)
        #expect(pickCustomRowLabel(query: " \t ", titles: [], allowCustom: true, verb: "Create workspace")
            == nil)
    }

    // the whole point of the second rule: subsequence ranking keeps `release` for the query `rl`, which
    // under `whenNothingMatched` makes `rl` impossible to create at any query length.
    @Test func loosePartialMatchStillOffersTheCreateRowUnderTheExactTitleRule() {
        #expect(pickCustomRowLabel(query: "rl", titles: ["release"], allowCustom: true,
                                   verb: "Create workspace", rule: .whenNoExactTitle)
            == "Create workspace \"rl\"")
        #expect(pickCustomRowLabel(query: "rl", titles: ["release"], allowCustom: true,
                                   verb: "Create workspace", rule: .whenNothingMatched) == nil)
    }

    @Test func exactTitleMatchDoesNotOfferTheCreateRow() {
        #expect(pickCustomRowLabel(query: "release", titles: ["release", "notes"], allowCustom: true,
                                   rule: .whenNoExactTitle) == nil)
        #expect(pickCustomRowLabel(query: "  release  ", titles: ["release"], allowCustom: true,
                                   rule: .whenNoExactTitle) == nil)
    }

    @Test func exactTitleMatchIsCaseSensitiveLikeWorkspaceLookup() {
        #expect(pickCustomRowLabel(query: "Release", titles: ["release"], allowCustom: true,
                                   verb: "Create workspace", rule: .whenNoExactTitle)
            == "Create workspace \"Release\"")
    }

    @Test func theExactTitleRuleStillRejectsBlankAndDisallowedQueries() {
        #expect(pickCustomRowLabel(query: " \t ", titles: ["release"], allowCustom: true,
                                   rule: .whenNoExactTitle) == nil)
        #expect(pickCustomRowLabel(query: "rl", titles: ["release"], allowCustom: false,
                                   rule: .whenNoExactTitle) == nil)
    }

    @Test func theExactTitleRuleOffersTheRowWhenNothingMatchedAtAll() {
        #expect(pickCustomRowLabel(query: "brand new", titles: [], allowCustom: true,
                                   verb: "Create workspace", rule: .whenNoExactTitle)
            == "Create workspace \"brand new\"")
    }
}
