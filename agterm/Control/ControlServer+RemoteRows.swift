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
        // a soft-closed companion is saved at its old index, which can sort it ahead of its parent: it waits for a
        // second pass, and the rows after it move up by one so the saved order holds
        var deferred: [RemoteRowBook.RestoreEntry] = []
        var deferredBefore: [UUID: Int] = [:]
        for entry in RemoteRowBook.restorePlan(records: records, windowID: windowID, store: store) {
            let parent = restoredParent(of: entry.record, in: entry.workspaceID, store: store)
            if entry.record.parentRemoteSessionID != nil, parent == nil {
                deferred.append(entry)
                deferredBefore[entry.workspaceID, default: 0] += 1
                continue
            }
            restoreRemoteRow(entry, parent: parent, position: entry.position - deferredBefore[entry.workspaceID, default: 0],
                             store: store)
        }
        // no position under a parent: each lands at its group's end, so deferred companions keep their saved order
        for entry in deferred {
            let parent = restoredParent(of: entry.record, in: entry.workspaceID, store: store)
            restoreRemoteRow(entry, parent: parent, position: parent == nil ? entry.position : nil, store: store)
        }
    }

    private func restoreRemoteRow(_ entry: RemoteRowBook.RestoreEntry, parent: UUID?, position: Int?, store: AppStore) {
        let record = entry.record
        let present = store.workspaces.flatMap(\.sessions).contains {
            $0.remoteHost == record.host && $0.remotePresentation?.binding.remoteSessionID == record.remoteSessionID
        }
        guard !present, let left = record.daemonsByPane[.left],
              let count = store.workspaces.first(where: { $0.id == entry.workspaceID })?.sessions.count else { return }
        let name = record.restoredName
        let row = RemoteRow(host: record.host, endpoint: record.endpoint, sessionName: record.sessionName,
                            remoteSessionID: record.remoteSessionID, presentationVersion: record.presentationVersion,
                            transport: record.transport, left: left, right: record.daemonsByPane[.right],
                            splitAxis: record.splitAxis, name: name.value, namePending: name.pending)
        let placement = RemotePlacement(store: store, workspace: entry.workspaceID, parent: parent,
                                        position: position.map { min(max($0, 0), count) }, select: false)
        _ = insertRemoteRow(row, at: placement, claim: false)
    }

    /// The one top-level row in the record's own workspace showing its saved parent; with none or several the row
    /// stands alone, since `addSession` links a parent even across workspaces.
    private func restoredParent(of record: RemoteRowBook.Record, in workspace: UUID, store: AppStore) -> UUID? {
        guard let parent = record.parentRemoteSessionID,
              let sessions = store.workspaces.first(where: { $0.id == workspace })?.sessions else { return nil }
        let rows = sessions.filter { row in
            guard row.parentID == nil, row.remoteHost == record.host, let binding = row.remotePresentation?.binding else { return false }
            return binding.remoteSessionID == parent && binding.origin?.endpoint == record.endpoint
        }
        return rows.count == 1 ? rows.first?.id : nil
    }
}
