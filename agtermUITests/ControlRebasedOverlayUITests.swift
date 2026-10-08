import XCTest

@MainActor
final class ControlRebasedOverlayUITests: ControlAPITestCase {
    // a missing app keeps the real /Applications/Rebased.app from starting inside the test instance
    override var seededSettings: [String: Any]? { ["rebasedAppPath": "/tmp/agterm-no-such-Rebased.app"] }

    func testOpenWithMissingAppReportsFailure() throws {
        let id = try activeSessionID()
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"rebased":true}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "\(open)")
        XCTAssertTrue(poll(until: (self.sessionTreeNode(id)?["rebasedOverlay"] as? [String: Any])?["state"] as? String == "failed",
                           timeout: 10), "the overlay should report the failed start")
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let rebased = try XCTUnwrap(((tree["result"] as? [String: Any])?["tree"] as? [String: Any])?["rebased"] as? [String: Any],
                                    "the tree should carry the JVM status: \(tree)")
        XCTAssertEqual(rebased["jvm"] as? String, "failed")
        XCTAssertNotNil(rebased["error"] as? String)
    }

    private func sessionTreeNode(_ id: String) -> [String: Any]? {
        guard let tree = try? sendCommand(#"{"cmd":"tree"}"#),
              let result = tree["result"] as? [String: Any], let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        return workspaces.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            .first { ($0["id"] as? String)?.lowercased() == id.lowercased() }
    }
}
