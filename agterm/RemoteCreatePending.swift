import Foundation
import Observation

/// Windows with a "+" remote create in flight. The one set is both the repeated-click guard and what the "+"
/// controls read to look disabled, so the two cannot drift.
@MainActor
@Observable
final class RemoteCreatePending {
    static let shared = RemoteCreatePending()

    private(set) var windows: Set<UUID> = []

    func contains(_ windowID: UUID?) -> Bool { windowID.map(windows.contains) ?? false }

    /// False when `windowID` already has a create in flight.
    func begin(_ windowID: UUID) -> Bool { windows.insert(windowID).inserted }

    func end(_ windowID: UUID) { windows.remove(windowID) }
}
