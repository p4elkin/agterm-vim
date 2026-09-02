import Foundation
import Testing
@testable import agtermCore

/// Wire coverage for the nested `ControlResult` payloads, where a key's name and its absence are the
/// contract an outside caller reads.
struct ControlPayloadsTests {
    private func inventory(socketDirectory: String) -> ControlZmxInventory {
        let result = ZmxInventory.join(
            observed: [ZmxSessionRecord(name: "agterm-3f2a", clients: 1, leaderPID: 11)],
            claims: [], inventoryComplete: true)
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                         unavailableReason: nil)
        return ControlZmxInventory(restore: status, result: result, socketDirectory: socketDirectory)
    }

    @Test func theSocketDirectoryRidesTheInventorySoAnOutsideAttachCanFindIt() throws {
        let payload = inventory(socketDirectory: "/tmp/agterm-zmx-e37fc371e9dbafce")
        let encoded = try JSONEncoder().encode(payload)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(json["socketDirectory"] as? String == "/tmp/agterm-zmx-e37fc371e9dbafce")
        let decoded = try JSONDecoder().decode(ControlZmxInventory.self, from: encoded)
        #expect(decoded == payload)
        #expect(decoded.socketDirectory == "/tmp/agterm-zmx-e37fc371e9dbafce")
    }

    @Test func anOlderServerOmittingTheDirectoryStillDecodes() throws {
        let older = """
        {"restore":{"configured":"live","requestedAtLaunch":"live","active":"live","restartRequired":false},
         "inventoryComplete":true,
         "entries":[{"daemon":"agterm-3f2a","state":"foreign","observation":"running","clients":1,
                     "leaderPID":11}]}
        """
        let decoded = try JSONDecoder().decode(ControlZmxInventory.self, from: Data(older.utf8))

        #expect(decoded.socketDirectory == nil)
        #expect(decoded.inventoryComplete)
        #expect(decoded.restore.active == "live")
        let entry = try #require(decoded.entries.first)
        #expect(entry.daemon == "agterm-3f2a")
        #expect(entry.clients == 1)
        #expect(entry.leaderPID == 11)
    }
}
