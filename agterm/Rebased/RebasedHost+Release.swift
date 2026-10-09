import Foundation

extension RebasedHost {
    func release(_ id: UUID) {
        guard let entry = removeEntry(id) else { return }
        if let captured = entry.onClose { runOnClose(captured) }
    }

    func releaseAllBeforeQuit() {
        for id in Array(entries.keys) { release(id) }
    }
}
