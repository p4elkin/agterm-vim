import Foundation

/// The app-wide visit order behind the cross-window recent picker (fork only), split out of
/// `WindowLibrary.swift` for the type-length limit.
extension WindowLibrary {
    /// Hooks a window's store into `appRecency`. A push is a visit only while its window is the active one,
    /// which is when the dwell ends: a background window's script select or close reselection never counts.
    /// A real close forgets from any window.
    func wireAppRecency(_ store: AppStore, windowID: UUID) {
        store.onRecencyPush = { [weak self] id in
            guard let self, self.activeWindowID == windowID else { return }
            self.appRecency.push(id)
        }
        store.onRecencyForget = { [weak self] id in
            self?.appRecency.forget([id])
        }
    }

    /// With no usable `session-recency.json`, starts the list from the open windows' own orders: the
    /// frontmost window's first, then the others in window order. Closed windows are not read.
    func seedAppRecencyIfFresh() {
        guard appRecency.isFresh else { return }
        let active = activeWindowID
        let ordered = (active.map { [$0] } ?? []) + openIDs().filter { $0 != active }
        appRecency.seed(ordered.compactMap { stores[$0] }.flatMap(\.sessionRecency.items))
    }
}
