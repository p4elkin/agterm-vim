import Foundation

/// Coalesces rapid repeated calls into a single deferred action: `schedule(after:_:)` cancels any pending
/// work and reschedules, so only the latest runs once the quiet window elapses; `flush()` runs it
/// synchronously (for a commit/quit path that must capture the latest state now); `cancel()` drops it.
///
/// `@MainActor` so the work runs on the main actor like its callers (AppStore saves, SettingsModel theme
/// preview). Foundation-only — host-free.
@MainActor
public final class Debouncer {
    private var work: DispatchWorkItem?
    private var action: (@MainActor () -> Void)?

    /// The delay the pending action was armed with, nil when nothing is pending. Exposed because a caller
    /// cannot otherwise tell a re-arm from a survivor: coalescing means both leave exactly one item, so the
    /// deadline is the only difference between "rescheduled on the new delay" and "still on the old one".
    public private(set) var pendingDelay: TimeInterval?

    /// Arms counted since init. Distinguishes "did not re-arm" from "re-armed identically", which is
    /// otherwise invisible for the same reason.
    public private(set) var scheduleCount = 0

    public init() {}

    /// Cancels any pending action and schedules `action` to run after `delay`. Only the
    /// most recently scheduled action survives, so a burst of calls collapses to one run.
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        work?.cancel()
        self.action = action
        pendingDelay = delay
        scheduleCount += 1
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Runs the pending action immediately (if any) and clears it. A no-op when nothing
    /// is pending. The deferred dispatch is cancelled so the action can't run twice.
    public func flush() {
        work?.cancel()
        fire()
    }

    /// Drops the pending action without running it.
    public func cancel() {
        work?.cancel()
        work = nil
        action = nil
        pendingDelay = nil
    }

    /// Runs and clears the pending action. Clearing first makes a re-entrant call a no-op.
    private func fire() {
        guard let action else { return }
        work = nil
        self.action = nil
        pendingDelay = nil
        action()
    }
}
