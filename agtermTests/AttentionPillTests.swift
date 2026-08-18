import agtermCore
import XCTest
@testable import agterm

/// Drives `WindowContentView.attentionPillSegments`, the exact function the pill body calls, so the rule for
/// which segments render can never disagree with what is drawn. The counting itself is covered host-free in
/// `AttentionCountsTests`; what is only true HERE is the zero-drop, the order, the badge gate and the
/// accessibility value.
@MainActor
final class AttentionPillTests: XCTestCase {
    private func segments(_ counts: AttentionCounts, badges: Bool = true) -> [AttentionPillSegment] {
        WindowContentView.attentionPillSegments(counts, badgesEnabled: badges)
    }

    func testNoSegmentsWhenEverythingIsZero() {
        XCTAssertTrue(segments(AttentionCounts()).isEmpty)
    }

    func testASingleNonZeroCategoryRendersOneSegment() {
        let blocked = segments(AttentionCounts(blocked: 1))
        XCTAssertEqual(blocked.map(\.category), [.blocked])
        XCTAssertEqual(blocked.map(\.count), [1])

        let unseenOnly = segments(AttentionCounts(unseen: 7))
        XCTAssertEqual(unseenOnly.map(\.category), [.unseen])
        XCTAssertEqual(unseenOnly.map(\.count), [7])
    }

    /// blocked, active, completed follow `AgentStatus.attentionRank`; unseen sits last.
    func testAllFourRenderInAttentionOrder() {
        let all = segments(AttentionCounts(blocked: 2, active: 3, completed: 1, unseen: 4))
        XCTAssertEqual(all.map(\.category), [.blocked, .active, .completed, .unseen])
        XCTAssertEqual(all.map(\.count), [2, 3, 1, 4])
    }

    func testAZeroCategoryIsOmittedFromTheMiddle() {
        XCTAssertEqual(segments(AttentionCounts(blocked: 1, completed: 5)).map(\.category), [.blocked, .completed])
    }

    func testTheBadgeToggleDropsUnseenAndNothingElse() {
        let all = segments(AttentionCounts(blocked: 2, active: 3, completed: 1, unseen: 4), badges: false)
        XCTAssertEqual(all.map(\.category), [.blocked, .active, .completed])
        XCTAssertEqual(all.map(\.count), [2, 3, 1])
    }

    /// The whole capsule hangs off this being empty rather than off `AttentionCounts.isEmpty`, which is still
    /// false here — gating the segments alone would draw a bare capsule with nothing in it.
    func testUnseenAloneWithBadgesOffRendersNoSegmentsAtAll() {
        let counts = AttentionCounts(unseen: 4)
        XCTAssertFalse(counts.isEmpty)
        XCTAssertTrue(segments(counts, badges: false).isEmpty)
    }

    func testEverySegmentSymbolResolvesAtTheDeploymentTarget() {
        for category in AttentionPillCategory.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: category.symbolName, accessibilityDescription: nil),
                            "\(category.symbolName) does not resolve")
        }
    }

    func testAccessibilityValueListsOnlyTheRenderedCounts() {
        let counts = AttentionCounts(blocked: 2, completed: 1, unseen: 4)
        XCTAssertEqual(WindowContentView.attentionPillAccessibilityValue(segments(counts)),
                       "blocked 2, completed 1, unseen 4")
        XCTAssertEqual(WindowContentView.attentionPillAccessibilityValue(segments(counts, badges: false)),
                       "blocked 2, completed 1")
        XCTAssertEqual(WindowContentView.attentionPillAccessibilityValue([]), "")
    }
}
