import Foundation
import agtermCore

/// The ssh pools of attached rows: a remote window's row rides its window's pool, any other ssh row its host's.
extension ControlServer {
    /// sshPool is row `sessionID`'s pool, live or pending close; nil for a local row or without a registry.
    func sshPool(forSession sessionID: UUID) -> SshConnectionPool? {
        if let pool = catalogPool(forSession: sessionID) { return pool }
        guard let pools = library.sshHostPools, let binding = heldSession(sessionID)?.remotePresentation?.binding,
              !binding.catalogOwned, let origin = binding.origin else { return nil }
        return pools.pool(for: origin.host)
    }

    /// retainHostPoolLeases releases the host pools' pane and stream users nothing holds any more. The set comes from rows,
    /// not mounted surfaces, so a line built and not yet mounted keeps its lease; an asleep row keeps only its stream and scratch.
    func retainHostPoolLeases() {
        guard let pools = library.sshHostPools else { return }
        var panes: Set<String> = []
        for id in library.openIDs() {
            guard let store = library.store(for: id) else { continue }
            let rows = store.workspaces.flatMap(\.sessions) + store.pendingCloseMembers().map(\.session)
            for row in rows where row.remoteHost != nil {
                if !row.ended, !row.asleep {
                    panes.insert("pane:\(row.paneIdentity)")
                    if row.hasSplit, let split = row.splitPaneIdentity { panes.insert("pane:\(split)") }
                }
                if row.originScratch != nil, let scratch = row.scratchClientIdentity { panes.insert("pane:\(scratch)") }
            }
        }
        pools.retain(panes, prefix: "pane:")
        pools.retain(Set(remoteClients.keys.map { "present:\($0)" }), prefix: "present:")
    }
}
