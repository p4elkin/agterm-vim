import Foundation
import Testing
@testable import agtermCore

struct ZmxListParserTests {
    @Test func parsesHealthyListing() {
        let output = [
            "  name=A1B2-left\tpid=74149\tclients=2\tcreated=1785829235\tstart_dir=/Users/sasha\tagterm_name=dam",
            "  name=A1B2-right\tpid=74161\tclients=1\tcreated=1785829235\tstart_dir=/Users/sasha/dev"
        ].joined(separator: "\n")

        let entries = ZmxListParser.parse(output)

        #expect(entries == [
            ZmxListParser.Entry(name: "A1B2-left", clients: 2, leaderPID: 74149),
            ZmxListParser.Entry(name: "A1B2-right", clients: 1, leaderPID: 74161)
        ])
    }

    @Test func parsesTheAttachedSessionMarkedWithAnArrow() {
        let entries = ZmxListParser.parse("→ name=A1B2-left\tpid=17309\tclients=1\tcreated=1785749697")

        #expect(entries == [ZmxListParser.Entry(name: "A1B2-left", clients: 1, leaderPID: 17309)])
    }

    @Test func keepsAZeroClientCountDistinctFromUnknown() {
        let entries = ZmxListParser.parse("  name=A1B2-left\tpid=900\tclients=0\tcreated=1")

        #expect(entries.first?.clients == 0)
    }

    @Test func anErrorLineReportsAnUnknownClientCount() {
        let output = [
            "  name=A1B2-left\terr=session unresponsive: error.Timeout\tstatus=unresponsive",
            "  name=A1B2-right\terr=daemon read err=EOF\tclients=0"
        ].joined(separator: "\n")

        let entries = ZmxListParser.parse(output)

        #expect(entries.map(\.name) == ["A1B2-left", "A1B2-right"])
        #expect(entries.allSatisfy { $0.clients == nil })
    }

    @Test func aNonNumericClientCountIsUnknown() {
        let entries = ZmxListParser.parse("  name=A1B2-left\tpid=900\tclients=many")

        #expect(entries.first?.clients == nil)
    }

    @Test func aLineWithNoLeaderPIDStillParses() {
        let entries = ZmxListParser.parse("  name=A1B2-left\tclients=0\tcreated=1785829235")

        #expect(entries == [ZmxListParser.Entry(name: "A1B2-left", clients: 0, leaderPID: nil)])
    }

    @Test func anUnusablePIDIsDropped() {
        #expect(ZmxListParser.parse("  name=A1B2-left\tpid=0\tclients=1").first?.leaderPID == nil)
        #expect(ZmxListParser.parse("  name=A1B2-left\tpid=zsh\tclients=1").first?.leaderPID == nil)
    }

    @Test func anEmptyListingYieldsNoEntries() {
        #expect(ZmxListParser.parse("").isEmpty)
        #expect(ZmxListParser.parse("no sessions found in /var/folders/x1/T/zmx\n").isEmpty)
        #expect(ZmxListParser.parse("name=\tpid=900\tclients=1").isEmpty)
    }

    @Test func aFieldOrderChangeDoesNotMoveTheName() {
        let entries = ZmxListParser.parse("  name=A1B2-left\tstart_dir=/Users/sasha\tclients=3\tpid=42")

        #expect(entries == [ZmxListParser.Entry(name: "A1B2-left", clients: 3, leaderPID: 42)])
    }

    @Test func aCommandFieldWithSpacesDoesNotSplitTheLine() {
        let output = "  name=A1B2-left\tpid=8515\tclients=1\tcmd=claude --model opus --add-dir /tmp a\tagterm_name=x"

        #expect(ZmxListParser.parse(output) == [ZmxListParser.Entry(name: "A1B2-left", clients: 1, leaderPID: 8515)])
    }
}
