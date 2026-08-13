import Foundation
import Observation

/// App-global overlay-redirect toggle: whether `session.overlay.open` may redirect an overlay to/from a
/// paired machine (the decision itself lives in `agtermCore`'s `OverlayRedirect.swift`; the pill reads
/// `isEnabled` alongside a session's pairing to derive its colour, task by task).
///
/// Modelled on `NormalModeController` — one shared instance, `@Observable` so the title-bar pill
/// re-renders — but UNLIKE normal mode this value is PERSISTED: `SettingsModel` is the only writer, seeding
/// the saved value at launch and pushing every change through `setEnabled(_:)` after it has saved. Sasha
/// should not have to re-arm this every time agterm launches.
@MainActor
@Observable
final class OverlayRedirectController {
    static let shared = OverlayRedirectController()

    private(set) var isEnabled = false

    private init() {}

    /// Set the live value, at launch from the persisted setting and afterwards on every change.
    /// `SettingsModel` calls this AFTER it has already persisted, so `isEnabled` never runs ahead of
    /// `settings.json`.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
    }
}
