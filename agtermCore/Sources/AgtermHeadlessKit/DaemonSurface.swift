import agtermCore
import Foundation

/// Stands in for a libghostty surface: the headless origin never renders, the pane IS its zmx daemon.
@MainActor
final class DaemonSurface: PaneRoleMutableSurface {
    let paneToken: String
    init(paneIdentity: UUID) { paneToken = paneIdentity.uuidString }
    func teardown() {}
    func promoteToPrimaryPane() {}
    func setPaneRole(_: SwappablePaneRole) {}
    var isRealized: Bool { true }
    var backedByZmx: Bool { true }
}
