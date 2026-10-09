import Foundation
import agtermCore

extension ControlServer {
    func openRebasedOverlay(in store: AppStore, sessionID id: UUID, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        guard let session = store.session(withID: id) else { return ControlResponse(ok: false, error: "no such session") }
        let view = options.rebasedView ?? options.rebasedDiff.map { RebasedView.diff($0, workingTree: false) }
        if session.remoteHost != nil {
            if let flag = Self.localRebasedFlag(view) { return Self.localRebasedRefusal(flag) }
            if options.rebasedProject != nil { return Self.localRebasedRefusal("project") }
            if options.rebasedOnClose != nil { return Self.localRebasedRefusal("on-close") }
        }
        switch RebasedHost.shared.openOverlay(in: store, session: id, cwd: options.cwd, sizePercent: options.sizePercent,
                                             view: view, pane: options.pane, project: options.rebasedProject, onClose: options.rebasedOnClose) {
        case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
        case .success(let opened):
            if options.follow { store.selectSession(id) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, overlay: opened.overlay.uuidString, request: opened.request))
        }
    }

    func closeSessionOverlay(_ target: String?, window: String?, overlay: UUID) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard store.closeRebasedOverlay(id, id: overlay) else { return ControlResponse(ok: false, error: "no matching Rebased overlay") }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, overlay: overlay.uuidString))
        }
    }

    func showRebasedView(_ target: String?, window: String?, view: RebasedView) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else { return ControlResponse(ok: false, error: "no such session") }
            if session.remoteHost != nil, let flag = Self.localRebasedFlag(view) { return Self.localRebasedRefusal(flag) }
            guard let held = session.rebasedPlacement else {
                return ControlResponse(ok: false, error: "no Rebased overlay in this session")
            }
            if let refusal = RebasedHost.shared.fetchRefusal(session: session) { return ControlResponse(ok: false, error: refusal) }
            let request = RebasedHost.shared.requestView(overlay: held.overlay.id, view: view)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, overlay: held.overlay.id.uuidString, request: request))
        }
    }

    func toggleRebasedOverlay(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            let text: String
            switch self.actions.toggleRebasedOverlay(session: id) {
            case .hidden: text = "hidden"
            case .shown: text = "shown"
            case .opened: text = "opened"
            case .refused(let reason): return ControlResponse(ok: false, error: reason)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: text,
                                                                   overlay: store.session(withID: id)?.rebasedPlacement?.overlay.id.uuidString))
        }
    }

    private static func localRebasedFlag(_ view: RebasedView?) -> String? {
        switch view?.kind {
        case .workingTree?: return "working-tree"
        case .file?: return "file"
        default: return nil
        }
    }

    private static func localRebasedRefusal(_ flag: String) -> ControlResponse {
        ControlResponse(ok: false, error: "--\(flag) works on a local row only")
    }
}
