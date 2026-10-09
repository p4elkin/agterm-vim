import Foundation

extension RebasedHost {
    func release(_ id: UUID, endingProcess: Bool = false) {
        guard let entry = removeEntry(id, endingProcess: endingProcess) else { return }
        if let captured = entry.onClose { runOnClose(captured) }
    }

    func releaseAllBeforeQuit() {
        for id in Array(entries.keys) { release(id, endingProcess: true) }
    }
}
