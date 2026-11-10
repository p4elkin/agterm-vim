import agtermCore
import Foundation

/// Brings a remote row's pane back after its attach ended. One tree call per host classifies every
/// waiting row: `attached` reattaches the pane without a lead claim, `disconnected` retries every
/// `retryInterval`, `endedOnHost` stops. A pane the origin closed is never reattached: either the last
/// layout removed it, or the tree no longer lists its daemon, and attaching would create a fresh one.
/// A failed presentation stream asks the same tree once whether its row's session ended, since a row
/// whose panes never exit after that is otherwise never classified again.
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
    private var rowChecks: [String: Set<UUID>] = [:]
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
        start(host)
    }

    /// Only `endedOnHost` is kept from the answer: the stream retries on its own, and a `disconnected` set
    /// here would have no waiting pane to clear it.
    func streamFailed(inSession id: UUID) {
        guard let session = library.store(forSession: id)?.session(withID: id), let host = session.remoteHost,
              let presentation = session.remotePresentation, presentation.binding.origin != nil,
              presentation.rowState != .endedOnHost else { return }
        rowChecks[host, default: []].insert(id)
        start(host)
    }

    private func start(_ host: String) {
        guard !checking.contains(host) else { return }
        checking.insert(host)
        Task { await self.supervise(host) }
    }

    private func supervise(_ host: String) async {
        while true {
            let panes = (waiting[host] ?? []).filter(isStillWaiting)
            let rows = rowChecks.removeValue(forKey: host) ?? []
            guard !panes.isEmpty || !rows.isEmpty else { break }
            waiting[host] = panes
            let answer = await tree(host)
            for pane in panes { settle(pane, host: host, answer: answer) }
            for row in rows { settleRow(row, answer: answer) }
            // a row check that arrived during the call goes out at once; only a waiting pane waits
            if waiting[host]?.isEmpty == false { await sleep(Self.retryInterval) }
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

    /// The tree omits a live session that is briefly not fully backed (a split whose daemon is not up yet), so a
    /// stream that reconnected while the call was out outranks the answer.
    private func settleRow(_ id: UUID, answer: ControlResponse) {
        guard let store = library.store(forSession: id), let presentation = store.session(withID: id)?.remotePresentation,
              presentation.connection != .connected,
              RemoteRowState.classify(tree: answer, binding: presentation.binding) == .endedOnHost else { return }
        store.setRemoteRowState(.endedOnHost, forSession: id)
    }
}
