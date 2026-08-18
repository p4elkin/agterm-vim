import agtermCore
import AppKit
import SwiftUI

/// One category the attention pill can draw. The cases ARE the render order: `blocked`/`active`/`completed`
/// follow `AgentStatus.attentionRank`, so the pill reads left to right the way the attention palette reads top
/// to bottom, and `unseen` sits last because it counts a different kind of thing. A fifth category (peer
/// messages) is an addition here plus one `AttentionCounts` field, not a restructure.
///
/// ⚠️ A distinct glyph per category, NOT the sidebar's configurable `StatusShape`. A lone number has to say
/// which category it is without depending on color, so the pill deliberately does not follow that setting.
enum AttentionPillCategory: String, CaseIterable {
    case blocked, active, completed, unseen

    var symbolName: String {
        switch self {
        case .blocked: return "hand.raised.fill"
        case .active: return "play.fill"
        case .completed: return "checkmark"
        case .unseen: return "envelope.fill"
        }
    }

    /// The status whose Settings tint this category borrows, so the pill follows the same colors as the
    /// sidebar glyphs. nil for `unseen`, which is not a status and takes `BadgeView`'s unread red instead.
    var status: AgentStatus? {
        switch self {
        case .blocked: return .blocked
        case .active: return .active
        case .completed: return .completed
        case .unseen: return nil
        }
    }

    func count(in counts: AttentionCounts) -> Int {
        switch self {
        case .blocked: return counts.blocked
        case .active: return counts.active
        case .completed: return counts.completed
        case .unseen: return counts.unseen
        }
    }
}

/// A category that has something to report, paired with how much. Only non-zero categories become segments.
struct AttentionPillSegment: Equatable {
    let category: AttentionPillCategory
    let count: Int
}

/// The attention-counts pill: one capsule holding a glyph-plus-count segment per non-zero category, so a
/// window whose sidebar is collapsed still says how much needs attention and of what kind. Rides `chromePills`
/// and therefore `sidebarOnScreen` — sidebar footer while the sidebar is up, floating bottom-right over the
/// terminal while it is not — and inherits the frontmost-window-only gate with it.
///
/// Informational only, never clickable: `floatingPillsLayer` fills the window and relies on
/// `allowsHitTesting(false)`, so anything interactive here would swallow every click in the window. Navigation
/// stays on ⌃⇧I and ⌃⌥↑/↓. It needs no `InterfaceElement` toggle for `overlayRedirectPill`'s reason: it is
/// already gated on the one condition that makes it mean anything, here having something to report.
extension WindowContentView {
    @ViewBuilder var attentionCountsPill: some View {
        // the segments, never `counts.isEmpty`, decide whether anything renders: the badge gate can empty the
        // list while the counts still hold an unseen value, and two sources of truth would draw a bare capsule.
        let segments = Self.attentionPillSegments(store.attentionCounts,
                                                  badgesEnabled: notificationBadgeEnabled)
        if !segments.isEmpty {
            HStack(spacing: 6) {
                ForEach(segments, id: \.category) { segment in
                    HStack(spacing: 2) {
                        Image(systemName: segment.category.symbolName)
                        Text("\(segment.count)")
                    }
                    .foregroundStyle(Self.attentionPillColor(segment.category))
                }
            }
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(terminalColor, in: Capsule())
            .overlay(Capsule().strokeBorder(chromeText.opacity(0.25)))
            // the footer packs this against four fixed-size controls in a `sidebarWidth` column that is never
            // clipped, so at the 160pt minimum an ungreedy pill is what keeps the trailing buttons on screen.
            .layoutPriority(-1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("attention-counts-pill")
            .accessibilityValue(Self.attentionPillAccessibilityValue(segments))
        }
    }

    /// The decision half of the pill, factored out of the view body so a test can drive it without
    /// instantiating `WindowContentView`: which categories render, in which order, with which counts.
    ///
    /// `badgesEnabled` gates `unseen` ALONE, matching `WorkspaceSidebar.effectiveUnseen` and
    /// `DockBadgeController`: the count keeps tracking while the toggle is off, so re-enabling shows it again
    /// at once, and the three status categories are no more gated by it than the sidebar's status glyph is.
    static func attentionPillSegments(_ counts: AttentionCounts,
                                      badgesEnabled: Bool) -> [AttentionPillSegment] {
        AttentionPillCategory.allCases
            .map { AttentionPillSegment(category: $0, count: $0.count(in: counts)) }
            .filter { $0.count > 0 }
            .filter { badgesEnabled || $0.category != .unseen }
    }

    /// What VoiceOver and a test read off the capsule, since neither the glyphs nor the tints are observable.
    static func attentionPillAccessibilityValue(_ segments: [AttentionPillSegment]) -> String {
        segments.map { "\($0.category.rawValue) \($0.count)" }.joined(separator: ", ")
    }

    private static func attentionPillColor(_ category: AttentionPillCategory) -> Color {
        guard let status = category.status else { return Color(nsColor: .systemRed) }
        return Color(nsColor: GhosttyApp.shared.statusColor(for: status))
    }
}
