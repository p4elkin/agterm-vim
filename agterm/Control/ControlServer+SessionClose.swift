import Foundation
import agtermCore

extension ControlServer {
    func closeSession(_ target: String?, window: String?) -> ControlResponse {
        closeSession(target, window: window, undoable: false)
    }

    func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        closeSessions(targets, window: window, undoable: false)
    }

    func closeSession(_ target: String?, window: String?, undoable: Bool) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            closeResolvedSession(id, in: store, undoable: undoable)
        }
    }

    func closeSessions(_ targets: [String], window: String?, undoable: Bool) -> ControlResponse {
        resolveBatchSessions(targets, window: window) { store, ids in
            guard ids.count > 1 else {
                guard let id = ids.first else { return ControlResponse(ok: false, error: "session.close requires at least one --target") }
                return closeResolvedSession(id, in: store, undoable: undoable)
            }
            let soft = closeGraceUndoEnabled
            let affected: Int
            if soft {
                // one grouped grace record is the batch behavior scripts cannot reproduce by looping.
                affected = store.softCloseSessions(ids) ? ids.count : 0
            } else {
                // match the GUI's immediate batch-close path when grace undo is disabled.
                affected = ids.reduce(into: 0) { count, id in
                    guard store.session(withID: id) != nil else { return }
                    store.closeSession(id)
                    count += 1
                }
            }
            // `ok` with the count (0 included) mirrors `placeSessions` — every id resolved, so no error arm.
            return ControlResponse(ok: true, result: ControlResult(affected: affected,
                                                                   undoable: undoable ? soft && affected > 0 : nil))
        }
    }

    private func closeResolvedSession(_ id: UUID, in store: AppStore, undoable: Bool) -> ControlResponse {
        if undoable, closeGraceUndoEnabled {
            guard store.softCloseSession(id) else { return ControlResponse(ok: false, error: "could not close session") }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, undoable: true))
        }
        store.closeSession(id)
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, undoable: undoable ? false : nil))
    }

    private var closeGraceUndoEnabled: Bool {
        settingsModel.settings.closeGraceUndoEnabled ?? true
    }
}
