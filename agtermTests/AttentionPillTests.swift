import agtermCore
import XCTest
@testable import agterm

/// Drives `WindowContentView.attentionPillSegments`, the exact function the pill body calls, so the rule for
/// which segments render can never disagree with what is drawn. The counting itself is covered host-free in
/// `AttentionCountsTests`; what is only true HERE is the zero-drop, the order, and the accessibility value.
@MainActor
final class AttentionPillTests: XCTestCase {
    func testNoSegmentsWhenEverythingIsZero() {
        XCTAssertTrue(WindowContentView.attentionPillSegments(AttentionCounts()).isEmpty)
    }

    func testASingleNonZeroCategoryRendersOneSegment() {
        let segments = WindowContentView.attentionPillSegments(AttentionCounts(blocked: 1))
        XCTAssertEqual(segments.map(\.category), [.blocked])
        XCTAssertEqual(segments.map(\.count), [1])

        let unseenOnly = WindowContentView.attentionPillSegments(AttentionCounts(unseen: 7))
        XCTAssertEqual(unseenOnly.map(\.category), [.unseen])
        XCTAssertEqual(unseenOnly.map(\.count), [7])
    }

    /// blocked, active, completed follow `AgentStatus.attentionRank`; unseen sits last.
    func testAllFourRenderInAttentionOrder() {
        let segments = WindowContentView.attentionPillSegments(
            AttentionCounts(blocked: 2, active: 3, completed: 1, unseen: 4))
        XCTAssertEqual(segments.map(\.category), [.blocked, .active, .completed, .unseen])
        XCTAssertEqual(segments.map(\.count), [2, 3, 1, 4])
    }

    func testAZeroCategoryIsOmittedFromTheMiddle() {
        let segments = WindowContentView.attentionPillSegments(AttentionCounts(blocked: 1, completed: 5))
        XCTAssertEqual(segments.map(\.category), [.blocked, .completed])
    }

    func testEverySegmentSymbolResolvesAtTheDeploymentTarget() {
        for category in AttentionPillCategory.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: category.symbolName, accessibilityDescription: nil),
                            "\(category.symbolName) does not resolve")
        }
    }

    func testAccessibilityValueListsOnlyTheRenderedCounts() {
        let counts = AttentionCounts(blocked: 2, completed: 1, unseen: 4)
        XCTAssertEqual(WindowContentView.attentionPillAccessibilityValue(counts), "blocked 2, completed 1, unseen 4")
        XCTAssertEqual(WindowContentView.attentionPillAccessibilityValue(AttentionCounts()), "")
    }
}
