import agtermCore
import Foundation

extension ControlServer {
    /// Puts back every open window's saved remote rows. Called once at launch, never from a scene task,
    /// which runs per window.
    func restoreRemoteRows(from book: RemoteRowBook) {
        let records = book.load()
        for id in library.openIDs() {
            guard let store = library.store(for: id) else { continue }
            restoreRemoteRows(records, windowID: id, store: store)
        }
    }

    /// Recreates a window's saved rows unselected, at their saved places, without claiming the lead: the
    /// Mac that last led is not necessarily this one. A row already in the store is not created again.
    func restoreRemoteRows(_ records: [RemoteRowBook.Record], windowID: UUID, store: AppStore) {
        for entry in RemoteRowBook.restorePlan(records: records, windowID: windowID, store: store) {
            let record = entry.record
            let present = store.workspaces.flatMap(\.sessions).contains {
                $0.remoteHost == record.host && $0.remotePresentation?.binding.remoteSessionID == record.remoteSessionID
            }
            guard !present, let left = record.daemonsByPane[.left],
                  let count = store.workspaces.first(where: { $0.id == entry.workspaceID })?.sessions.count else { continue }
            let row = RemoteRow(host: record.host, endpoint: record.endpoint, sessionName: record.sessionName,
                                remoteSessionID: record.remoteSessionID, presentationVersion: record.presentationVersion,
                                transport: record.transport, left: left, right: record.daemonsByPane[.right],
                                splitAxis: record.splitAxis)
            let placement = RemoteRowPlacement(store: store, workspace: entry.workspaceID,
                                               position: min(entry.position, count), select: false)
            _ = insertRemoteRow(row, at: placement, claim: false)
        }
    }
}
