import Foundation
import Testing
@testable import agtermCore

struct ZmxSessionKeyTests {
    private static let uuidText = "0AFE1111-2222-3333-4444-555555555555"

    private func sessionID() throws -> UUID {
        try #require(UUID(uuidString: Self.uuidText))
    }

    @Test func keyNamesTheMainPaneLeftAndTheSplitRight() throws {
        let id = try sessionID()
        #expect(ZmxSessionKey.key(sessionID: id, isSplit: false) == "\(Self.uuidText)-left")
        #expect(ZmxSessionKey.key(sessionID: id, isSplit: true) == "\(Self.uuidText)-right")
    }

    @Test func isOwnedAcceptsEveryRoleIncludingTheOnesTheAppNeverCreates() {
        for role in ZmxSessionKey.Role.allCases {
            #expect(ZmxSessionKey.isOwned("\(Self.uuidText)-\(role.rawValue)"))
        }
    }

    @Test func isOwnedAcceptsALowercaseUUIDSoAHandWrittenKeyStaysReapable() {
        #expect(ZmxSessionKey.isOwned("\(Self.uuidText.lowercased())-left"))
    }

    @Test func isOwnedRejectsForeignNames() {
        let foreign = [
            "not-a-uuid-left",
            "\(Self.uuidText)-middle",
            "\(Self.uuidText)",
            "\(Self.uuidText)-left-left",
            "left",
            "",
        ]
        for name in foreign {
            #expect(!ZmxSessionKey.isOwned(name), "\(name) must not read as a pane key")
        }
    }

    @Test func parseRoundTripsBothRolesTheAppProduces() throws {
        let id = try sessionID()
        for (isSplit, role) in [(false, ZmxSessionKey.Role.left), (true, .right)] {
            let parsed = ZmxSessionKey.parse(ZmxSessionKey.key(sessionID: id, isSplit: isSplit))
            #expect(parsed == ZmxSessionKey.Parsed(sessionID: id, role: role))
        }
    }

    @Test func maxByteCountCoversTheLongestOwnedKey() {
        let longest = ZmxSessionKey.Role.allCases
            .map { "\(Self.uuidText)-\($0.rawValue)".utf8.count }
            .max()
        #expect(longest == ZmxSessionKey.maxByteCount)
    }

    /// The key takes the session id and nothing else, so no label change can orphan a running daemon.
    @Test @MainActor func keyIsStableAcrossARename() {
        let session = Session(id: UUID(), initialCwd: "/start", customName: "review")
        let before = ZmxSessionKey.key(sessionID: session.id, isSplit: false)
        session.customName = "build"
        session.currentCwd = "/elsewhere"
        #expect(ZmxSessionKey.key(sessionID: session.id, isSplit: false) == before)
    }
}
