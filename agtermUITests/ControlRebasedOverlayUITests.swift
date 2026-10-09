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

    func testPaneOpenWithMissingAppReportsFailureAndCloseRunsOnClose() throws {
        let id = try activeSessionID()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-rebased-closed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let split = try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "\(split)")
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"rebased":true,"pane":"left","onClose":"touch \#(marker.path)"}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "\(open)")
        let overlay = try XCTUnwrap((open["result"] as? [String: Any])?["overlay"] as? String, "\(open)")
        XCTAssertTrue(poll(until: (self.sessionTreeNode(id)?["rebasedOverlay"] as? [String: Any])?["state"] as? String == "failed",
                           timeout: 10), "the pane overlay should report the failed start")
        let node = try XCTUnwrap(sessionTreeNode(id)?["rebasedOverlay"] as? [String: Any])
        XCTAssertEqual(node["pane"] as? String, "left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let close = try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)","args":{"overlay":"\#(overlay)"}}"#)
        XCTAssertEqual(close["ok"] as? Bool, true, "\(close)")
        XCTAssertTrue(poll(until: FileManager.default.fileExists(atPath: marker.path), timeout: 10), "close should run --on-close")
    }

    private func sessionTreeNode(_ id: String) -> [String: Any]? {
        guard let tree = try? sendCommand(#"{"cmd":"tree"}"#),
              let result = tree["result"] as? [String: Any], let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        return workspaces.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            .first { ($0["id"] as? String)?.lowercased() == id.lowercased() }
    }
}
