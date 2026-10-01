import agtermCore
import Foundation

/// Brings a remote row's pane back after its attach ended. One tree call per host classifies every
/// waiting row: `attached` reattaches the pane without a lead claim, `disconnected` retries every
/// `retryInterval`, `endedOnHost` stops. A pane the origin closed is never reattached: either the last
/// layout removed it, or the tree no longer lists its daemon, and attaching would create a fresh one.
@MainActor
final class RemoteRowSupervisor {
    struct Pane: Hashable {
        let session: UUID
        let local: UUID
    }

    static let retryInterval: TimeInterval = 30

    private let library: WindowLibrary
    private let tree: (String) async -> ControlResponse
    private let sleep: (TimeInterval) async -> Void
    private let reattach: (Pane) -> Void
    private var waiting: [String: Set<Pane>] = [:]
    private var checking: Set<String> = []

    init(library: WindowLibrary, tree: @escaping (String) async -> ControlResponse,
         sleep: @escaping (TimeInterval) async -> Void, reattach: @escaping (Pane) -> Void) {
        self.library = library
        self.tree = tree
        self.sleep = sleep
        self.reattach = reattach
    }

    func paneExited(_ local: UUID, inSession id: UUID) {
        guard let store = library.store(forSession: id), let session = store.session(withID: id),
              let host = session.remoteHost, session.remotePresentation?.binding.origin != nil,
              !store.canCloseRemovedRemotePane(local, forSession: id) else { return }
        waiting[host, default: []].insert(Pane(session: id, local: local))
        guard !checking.contains(host) else { return }
        checking.insert(host)
        Task { await self.supervise(host) }
    }

    private func supervise(_ host: String) async {
        while true {
            let panes = (waiting[host] ?? []).filter(isStillWaiting)
            guard !panes.isEmpty else { break }
            waiting[host] = panes
            let answer = await tree(host)
            for pane in panes { settle(pane, host: host, answer: answer) }
            guard waiting[host]?.isEmpty == false else { break }
            await sleep(Self.retryInterval)
        }
        waiting[host] = nil
        checking.remove(host)
    }

    private func isStillWaiting(_ pane: Pane) -> Bool {
        guard let store = library.store(forSession: pane.session), let session = store.session(withID: pane.session) else {
            return false
        }
        return session.paneRole(forIdentity: pane.local) != nil && !store.canCloseRemovedRemotePane(pane.local, forSession: pane.session)
    }

    private func settle(_ pane: Pane, host: String, answer: ControlResponse) {
        guard let store = library.store(forSession: pane.session), let session = store.session(withID: pane.session),
              let binding = session.remotePresentation?.binding,
              let state = RemoteRowState.classify(tree: answer, binding: binding) else {
            waiting[host]?.remove(pane)
            return
        }
        store.setRemoteRowState(state, forSession: pane.session)
        guard state != .disconnected else { return }
        waiting[host]?.remove(pane)
        guard state == .attached, let daemon = binding.daemon(forLocalPane: pane.local),
              let listed = answer.result?.remote?.sessions.first(where: { $0.id == binding.remoteSessionID }),
              listed.panes.contains(where: { $0.daemon == daemon }) else { return }
        store.releaseRemotePaneHold(pane.local, forSession: pane.session)
        reattach(pane)
    }
}
