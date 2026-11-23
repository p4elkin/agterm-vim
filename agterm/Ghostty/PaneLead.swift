import agtermCore
import AppKit
import os

private let leadLogger = Logger(subsystem: "com.umputun.agterm", category: "PaneLead")

/// App side of explicit zmx leadership: a pane's zmx client reports its role, a pane that does not lead
/// is covered, and taking the lead is always a FRESH attach into a new surface. The covered surface drew
/// output laid out for another grid, so repairing it in place would need a resize and a replay ordered
/// against libghostty's own queued resize; a new surface starts from the daemon's snapshot instead.
/// `.claude/rules/control-api.md` owns the contract.
@MainActor
enum PaneLead {
    static let coveredRefusal = "pane is covered while another Mac leads it; take the lead first (session lead)"
    /// Replaces a pane's surface with a fresh attach. Installed once by the app, which owns the factories.
    static var reattach: ((_ old: GhosttySurfaceView, _ claim: Bool) -> Void)?
    /// replace swaps a pane's surface for one built from `launch`, uncovered. Installed once by the app.
    static var replace: ((_ old: GhosttySurfaceView, _ launch: PaneReattach, _ lead: ZmxLeadAttachment) -> GhosttySurfaceView?)?
    /// Tells the pane's store that read-back changed.
    static var roleChanged: ((_ view: GhosttySurfaceView) -> Void)?
    /// Parks a pane whose ssh lost the connection until the host answers again, with the nonce of the attach
    /// that led when it dropped. Installed by the app.
    static var waitToReconnect: ((_ view: GhosttySurfaceView, _ cover: Bool, _ reclaim: String?) -> Void)?
    /// Attaches a parked pane again without the claim, covered until its first report when `cover`, taking back
    /// the lead `reclaim` names while nobody used it since. False when nothing was attached.
    static var reconnect: ((_ old: GhosttySurfaceView, _ cover: Bool, _ reclaim: String?) -> Bool)?
    /// scratchStopped parks a remote window's scratch whose attach lost its link or ended; false for any other view.
    /// Installed by the app.
    static var scratchStopped: ((_ view: GhosttySurfaceView) -> Bool)?
    /// catalogChannel leases a remote row's pane its ssh channel on the row's pool: its remote window's, else its host's;
    /// nil for a mosh or local row. Installed by the app.
    static var catalogChannel: ((_ session: UUID, _ user: String) -> String?)?
    /// heldExit hands a remote pane's clean exit to the respawn join. Installed by the app.
    static var heldExit: ((_ view: GhosttySurfaceView) -> Void)?
    /// ownerRespawn reads a daemon's leader before a parent respawns, then returns what publishes the respawn.
    static var ownerRespawn: ((_ session: UUID, _ daemon: String) -> () -> Void)?
    /// Runs `work` once `delay` has passed. A seam, so a test fires a report deadline by hand.
    static var after: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            work()
        }
    }
    /// Whether a pane's program was spawned. A seam: a test's surface never spawns.
    static var hasSpawned: (_ view: GhosttySurfaceView) -> Bool = { $0.isRealized }

    /// The key that took a pane over, swallowed until it is released so neither its repeats nor its
    /// release reach the program through the new surface.
    private static var takeoverKeyCode: UInt16?

    /// A role report parsed off the title callback. One from a surface this pane already replaced
    /// carries that attachment's token and the book drops it.
    static func report(_ notice: ZmxLeadNotice, from view: GhosttySurfaceView) {
        guard !view.isDestroyed, let pane = UUID(uuidString: view.paneToken),
              let role = ZmxLeadBook.shared.apply(notice, pane: pane) else { return }
        RemoteRespawnBook.shared.acknowledged(pane: pane)
        roleChanged?(view)
        // a pane this Mac created or opened, whose attach started before it knew to claim
        if ZmxLeadBook.shared.takeClaim(pane: pane), role != .leader {
            reattach?(view, true)
            return
        }
        // without the claim, so this attach leads only if nobody claimed the session in the meantime
        if role == .unowned { reattach?(view, false) }
    }

    /// The attach wrapper's lost-connection report. Only the pane's current attachment is believed, and
    /// only an origin that reported a role before will report one after the attach, so only it is covered.
    /// A reconnect that lost the link before its first report inherits that from the attach it replaced.
    ///
    /// A pane with no attachment on record is believed too. Nothing contradicts the report then, and a
    /// pane whose state was forgotten under a live attach would otherwise sit on the reconnecting bar for
    /// good: its wrapper waits for the app, and the app would wait for nothing.
    static func linkLost(_ notice: RemoteLinkNotice, from view: GhosttySurfaceView) {
        if !view.isDestroyed, scratchStopped?(view) == true { return }
        guard !view.isDestroyed, let pane = UUID(uuidString: view.paneToken) else { return }
        let state = ZmxLeadBook.shared.states[pane]
        guard state.map({ $0.attachment.nonce == notice.nonce }) ?? true else { return }
        waitToReconnect?(view, state.map { $0.role != nil || $0.reattaching || $0.stalled } ?? false, state?.reclaimAfterDrop)
    }

    /// Arms the report deadline of a covered fresh attach. A daemon that takes the attach and never
    /// reports would otherwise leave the pane covered for good, with every key swallowed. A silent attach
    /// is replaced without the claim; `ZmxLeadBook` bounds that, and then the cover asks for a key.
    static func awaitReport(from view: GhosttySurfaceView, pane: UUID, nonce: String) {
        after(ZmxLeadBook.reportDeadline) { [weak view] in
            guard let view, !view.isDestroyed, ZmxLeadBook.shared.states[pane]?.attachment.nonce == nonce else { return }
            // a pane that has not spawned yet has had no chance to report
            guard hasSpawned(view) else { return awaitReport(from: view, pane: pane, nonce: nonce) }
            switch ZmxLeadBook.shared.overdue(pane: pane, nonce: nonce) {
            case .attachAgain:
                leadLogger.notice("pane \(pane, privacy: .public): no role report after the attach, attaching again")
                // an attach that could not start keeps this surface, so its deadline is armed again
                // a silent attach has no role, so this carries on whatever lead it was taking back
                let reclaim = ZmxLeadBook.shared.states[pane]?.reclaimAfterDrop
                if reconnect?(view, true, reclaim) != true { awaitReport(from: view, pane: pane, nonce: nonce) }
            case .stalled:
                leadLogger.notice("pane \(pane, privacy: .public): still no role report, left to a key press")
                roleChanged?(view)
            case nil:
                break
            }
        }
    }

    /// True when `event` belongs to a takeover or a pane waiting to reconnect, and must not reach the terminal.
    static func consumes(_ event: NSEvent, in view: GhosttySurfaceView) -> Bool {
        // the takeover key's release can land on the destroyed old view, or on nothing while the new one
        // mounts, and never reach this. A fresh press of the same key proves it was released.
        if event.type == .keyDown, !event.isARepeat, event.keyCode == takeoverKeyCode { takeoverKeyCode = nil }
        if event.type == .keyUp, event.keyCode == takeoverKeyCode {
            takeoverKeyCode = nil
            return true
        }
        if event.type == .keyDown, event.isARepeat, event.keyCode == takeoverKeyCode { return true }
        let pane = UUID(uuidString: view.paneToken)
        if RemoteReconnectBook.shared.waiting(pane: pane), let pane {
            // Command chords outside the menu still reach Ghostty's keybinds
            guard !event.modifierFlags.contains(.command) else { return false }
            if event.type == .keyDown, !event.isARepeat {
                // latched like a takeover key: still held when the fresh surface arrives, its repeats would
                // otherwise reach a covered pane and take the lead with a claim
                takeoverKeyCode = event.keyCode
                RemoteReconnectBook.shared.retryNow(pane: pane, now: Date())
            }
            return true
        }
        guard view.leadCovered else { return false }
        // a modifier alone is not the press the cover asks for, and app shortcuts stay the app's
        guard event.type == .keyDown, !event.modifierFlags.contains(.command) else { return true }
        // a key held since before a drop sends only repeats while the pane waits, so it was never latched
        guard !event.isARepeat else { return true }
        if let pane, let state = ZmxLeadBook.shared.states[pane], state.reattaching {
            // a reconnect or the unowned retry claims nothing, so the press makes its first report take the lead;
            // a takeover is already on its way, its fresh surface covered until that report
            if !state.attachment.claim {
                takeoverKeyCode = event.keyCode
                ZmxLeadBook.shared.claimOnReport(pane: pane)
            }
            return true
        }
        takeoverKeyCode = event.keyCode
        reattach?(view, true)
        return true
    }
}

/// What a fresh attach of an existing pane spawns with. It attaches and never creates: the trailing
/// `/bin/sh -c` runs only when the daemon is gone, and fails, so a vanished session ends the pane
/// instead of handing back a new shell under the old identity.
struct PaneReattach {
    let command: String
    let wait: Bool
    let environment: [String: String]
    let workingDirectory: String

    @MainActor
    static func launch(replacing old: GhosttySurfaceView, session: Session, identity: UUID,
                       lead: ZmxLeadAttachment) -> PaneReattach? {
        if old.backedByZmx {
            guard let zmx = ZmxLaunch.configuration(paneIdentity: identity, pane: old.isSplitPane ? "split" : "primary",
                                                    environment: old.env, lead: lead) else { return nil }
            let gone = "printf '%s\\n' 'agterm: session is gone'; exit 1"
            return PaneReattach(command: CommandRestore.shellQuotedLine(zmx.attachArguments + ["/bin/sh", "-c", gone]),
                                wait: false, environment: zmx.environment, workingDirectory: old.workingDirectory)
        }
        guard let command = session.remotePresentation?.binding.attachPaneCommand(
            forLocalPane: identity, pane: old.isSplitPane ? .right : .left, lead: lead,
            controlPath: PaneLead.catalogChannel?(session.id, "pane:\(identity)"))
        else { return nil }
        return PaneReattach(command: command, wait: true, environment: old.env, workingDirectory: old.workingDirectory)
    }

    /// originScratch is a fresh attach of the scratch an attached row shows from its origin.
    @MainActor
    static func originScratch(replacing old: GhosttySurfaceView, session: Session, identity: UUID,
                              lead: ZmxLeadAttachment) -> PaneReattach? {
        // leased under the scratch's client identity, which the retain keeps, never the daemon's `identity`
        let controlPath = session.scratchClientIdentity.flatMap { PaneLead.catalogChannel?(session.id, "pane:\($0)") }
        guard let binding = session.remotePresentation?.binding, let origin = binding.origin,
              let command = try? RemoteSession.attachPaneCommand(host: origin.host, endpoint: origin.endpoint,
                                                                 daemon: binding.scratchDaemon(for: identity), session: "scratch",
                                                                 pane: .left, lead: lead, controlPath: controlPath)
        else { return nil }
        return PaneReattach(command: command, wait: true, environment: old.env, workingDirectory: old.workingDirectory)
    }
}

extension GhosttySurfaceView {
    /// Whether this pane's terminal must not be seen or typed into: it follows another client's grid, or
    /// it is a fresh attach that has not reported yet.
    var leadCovered: Bool { ZmxLeadBook.shared.covered(pane: UUID(uuidString: paneToken)) }
}
