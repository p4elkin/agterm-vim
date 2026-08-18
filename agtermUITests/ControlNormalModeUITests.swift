import Foundation
import XCTest

/// Control-channel e2e for `mode` (normal mode) and its `window list` read-back. Subclass of
/// `ControlAPITestCase`, so it speaks an isolated socket in an isolated state dir.
@MainActor
final class ControlNormalModeUITests: ControlAPITestCase {
    /// The `normalMode` flag of the frontmost window, from a fresh `window.list`; nil when omitted.
    private func frontmostNormalMode() throws -> Bool? {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        let windows = try XCTUnwrap((response["result"] as? [String: Any])?["windows"] as? [[String: Any]],
                                    "window.list should carry windows: \(response)")
        return windows.first { $0["active"] as? Bool == true }?["normalMode"] as? Bool
    }

    private var pill: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "normal-mode-pill").firstMatch
    }

    // the mode is invisible from the outside except through the pill and the read-back, which is why the
    // command owes both: a caller that turned it on and cannot see it has no way to turn it back off safely.
    func testModeOnShowsIndicatorAndReadsBackOnTheWindow() throws {
        XCTAssertNil(try frontmostNormalMode(), "a fresh window reports no mode at all")

        XCTAssertEqual(try sendCommand(#"{"cmd":"mode","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "mode on should succeed with a window up")
        // read-back BEFORE the pill, and the order is load-bearing. `pill` walks the whole app with
        // `descendants(matching: .any)`, which on a freshly launched window has to build the terminal
        // grid's accessibility tree first; that snapshot alone can outlast a 10s timeout, so querying it
        // as the first thing after `mode on` fails without ever reaching the pill. One control round trip
        // is enough for the app to go idle and the snapshot to come back cheap.
        XCTAssertTrue(poll(until: (try? frontmostNormalMode()) == true, timeout: 10),
                      "window.list should report the mode on the frontmost window")
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the titlebar should show the normal-mode pill")

        // toggle is the same state machine, so it must LEAVE from on rather than re-enter.
        XCTAssertEqual(try sendCommand(#"{"cmd":"mode","args":{"mode":"toggle"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pill.waitForNonExistence(timeout: 10), "leaving the mode should remove the pill")
        XCTAssertTrue(poll(until: (try? frontmostNormalMode()) == nil, timeout: 10),
                      "the flag is omitted again once the mode is off, not reported false")
    }

    // an unknown token must not silently toggle: entering takes the keyboard away from the terminal.
    func testModeRejectsUnknownToken() throws {
        let response = try sendCommand(#"{"cmd":"mode","args":{"mode":"normal"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "an unknown mode token should error")
        XCTAssertEqual(response["error"] as? String, "invalid mode: normal")
        XCTAssertFalse(pill.exists, "a rejected command must not have entered the mode")
    }
}
