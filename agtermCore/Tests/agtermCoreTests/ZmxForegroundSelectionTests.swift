import Foundation
import Testing
@testable import agtermCore

struct ZmxForegroundSelectionTests {
    private let sessionID = UUID(uuidString: "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F")!
    private var leftKey: String { "\(sessionID.uuidString)-left" }
    private var wrapperArgv: [String] { ["/opt/homebrew/bin/zmx", "attach", leftKey] }
    private var listing: [ZmxListParser.Entry] {
        [ZmxListParser.Entry(name: leftKey, clients: 1, leaderPID: 74149)]
    }

    @Test func detectsTheWrapperAndReportsItsLeader() {
        #expect(ZmxForegroundSelection.decide(argv: wrapperArgv, listing: listing)
            == .inspect(leaderPID: 74149, key: leftKey))
    }

    @Test func detectsTheKeepShellOpenWrapper() {
        let argv = ["/opt/homebrew/bin/zmx", "attach", leftKey, "/bin/zsh", "-lc", "claude; exec /bin/zsh -l"]

        #expect(ZmxForegroundSelection.decide(argv: argv, listing: listing)
            == .inspect(leaderPID: 74149, key: leftKey))
    }

    @Test func leavesAPlainProcessAlone() {
        for argv in [["-zsh"], ["/bin/zsh"], ["claude"], [], ["/opt/homebrew/bin/zmx", "list"]] {
            #expect(ZmxForegroundSelection.decide(argv: argv, listing: listing) == .keepArgv)
            #expect(ZmxForegroundSelection.wrappedKey(argv: argv) == nil)
        }
    }

    /// A hand-picked or remote session is a real zmx client in that pane, not agterm's wrapper.
    @Test func leavesAForeignAttachAlone() {
        let argv = ["/opt/homebrew/bin/zmx", "attach", "dam"]
        let foreign = [ZmxListParser.Entry(name: "dam", clients: 1, leaderPID: 74149)]

        #expect(ZmxForegroundSelection.decide(argv: argv, listing: foreign) == .keepArgv)
    }

    @Test func aBinaryMerelyEndingInZmxIsNotTheWrapper() {
        #expect(ZmxForegroundSelection.wrappedKey(argv: ["/usr/local/bin/zmxproxy", "attach", leftKey]) == nil)
    }

    @Test func anUnreadableListingFallsBackToTheArgv() {
        #expect(ZmxForegroundSelection.decide(argv: wrapperArgv, listing: nil) == .keepArgv)
    }

    @Test func aKeyMissingFromTheListingFallsBackToTheArgv() {
        #expect(ZmxForegroundSelection.decide(argv: wrapperArgv, listing: []) == .keepArgv)
    }

    @Test func anUnknownLeaderPIDFallsBackToTheArgv() {
        let unplaceable = [ZmxListParser.Entry(name: leftKey, clients: 1, leaderPID: nil)]

        #expect(ZmxForegroundSelection.decide(argv: wrapperArgv, listing: unplaceable) == .keepArgv)
    }

    @Test func recognisesTheKeyThroughABarePathAndEitherRole() {
        let rightKey = "\(sessionID.uuidString)-right"

        #expect(ZmxForegroundSelection.wrappedKey(argv: ["zmx", "attach", leftKey]) == leftKey)
        #expect(ZmxForegroundSelection.wrappedKey(argv: ["zmx", "attach", rightKey]) == rightKey)
    }
}
