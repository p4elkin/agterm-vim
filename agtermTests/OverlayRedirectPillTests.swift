import agtermCore
import XCTest
@testable import agterm

/// Drives `WindowContentView.overlayRedirectPillState`, the exact function the titlebar pill calls, rather
/// than mirroring `OverlayRedirect.outcome`'s rule here — a second copy could drift from the view. The
/// grey/green/red rule itself is covered host-free in `OverlayRedirectTests`; what is only true HERE is the
/// mapping from the active session (which may be nil) to that rule's inputs.
@MainActor
final class OverlayRedirectPillTests: XCTestCase {
    private func session() -> Session { Session(initialCwd: NSTemporaryDirectory()) }

    func testTheActiveSessionsPairingReachesTheRule() {
        let mirroring = session()
        mirroring.mirrorsSession = OverlayMirrorSource(host: "workstation", session: "abc")
        XCTAssertEqual(WindowContentView.overlayRedirectPillState(session: mirroring, now: 1_000), .green)

        let watched = session()
        watched.viewer = OverlayViewer(host: "laptop", row: "xyz", confirmedAt: 1_000)
        XCTAssertEqual(WindowContentView.overlayRedirectPillState(session: watched, now: 1_010), .red)
    }

    /// No session with focus (e.g. a window with no sessions yet) reads the same as no pairing: grey.
    func testGreyWithNoActiveSession() {
        XCTAssertEqual(WindowContentView.overlayRedirectPillState(session: nil, now: 1_000), .grey)
        XCTAssertEqual(WindowContentView.overlayRedirectPillState(session: session(), now: 1_000), .grey)
    }
}
