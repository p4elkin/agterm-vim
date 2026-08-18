import Foundation

/// Whether a pane's command becomes `zmx attach <key>`, and the exact line when it does. Pure, so every
/// branch of the rule is unit-tested off the surface factories; the app target owns only the effects
/// (`ZmxClient`) and the libghostty handoff.
///
/// The rule reproduces what the `~/.zprofile` hook does today: it wraps the panes that would have run an
/// interactive login shell, and only those. A row with a pinned command has no login shell for the hook to
/// fire in, so it is not zmx-backed today and stays that way — which also keeps the laptop's mirrored rows
/// out of the wrapping, since `agterm-zmx-mirror` creates every one with `--command`.
public enum ZmxWrap {
    /// What a surface factory should do with the pane's command.
    public enum Decision: Equatable, Sendable {
        /// Run this command line instead of what the pane would have run; the pane owns zmx session `key`.
        case wrap(command: String, key: String)
        /// Leave the pane exactly as it would be without zmx — a login shell, or its own pinned command.
        /// `reason` is for the log only: every reason here is a normal outcome, never a failure.
        case unwrapped(reason: String)
    }

    /// - `sessionID` and `role` form the key. `ZmxSessionKey.Role` has no scratch or overlay case, so a
    ///   surface that is not a persistent row cannot be offered here at all.
    /// - `existingKey`: the key this pane already owns (`Session.zmxPrimaryKey`/`zmxSplitKey`), used verbatim
    ///   instead of the role-derived one. A promoted split survivor is the main pane of a `-right` session, so
    ///   deriving would re-attach it to a fresh `-left` and strand the daemon holding its agent. Ignored
    ///   unless it parses as a key of THIS session, so a hand-edited snapshot cannot name a foreign socket.
    /// - `siblingKey`: the key the row's OTHER pane owns (`Session.zmxSplitKey` when deciding for the main
    ///   pane, `zmxPrimaryKey` when deciding for the split). A pane never takes a key its sibling holds — see
    ///   `decide` for the promoted-row case that would otherwise put two panes on one daemon.
    /// - `pinnedCommand`: the row's `initialCommand`. nil OR blank means a plain login shell — `""` already
    ///   means "pinned to no command" elsewhere in the model (`Session.restoreCommand`).
    /// - `keepShellOpen`: run the command inside zmx's own shell so the row survives it exiting.
    /// - `shell`: the user's `$SHELL`, read only by the keep-shell-open form.
    /// - `zmxPath`: the located binary, nil when zmx is not installed.
    /// - `budgetReason`: `ZmxSocketBudget.probe`'s answer; non-nil means the socket could not bind.
    /// - `isolatedStateDir`: `AGTERM_STATE_DIR` is set, so this is a dev or test instance. It wraps nothing,
    ///   which is what keeps a hosted run from leaving a daemon behind or adopting the deployed app's.
    /// - `skipRequested`: `AGTERM_ZMX_SKIP` is set to something non-empty. The escape hatch for a pane that
    ///   should stay plain, honoured here because the zprofile hook that used to read it is being retired.
    public struct Inputs: Equatable, Sendable {
        public let sessionID: UUID
        public let role: ZmxSessionKey.Role
        public let existingKey: String?
        public let siblingKey: String?
        public let pinnedCommand: String?
        public let keepShellOpen: Bool
        public let shell: String
        public let zmxPath: String?
        public let budgetReason: String?
        public let isolatedStateDir: Bool
        public let skipRequested: Bool

        public init(sessionID: UUID, role: ZmxSessionKey.Role, existingKey: String?, siblingKey: String?,
                    pinnedCommand: String?, keepShellOpen: Bool, shell: String, zmxPath: String?,
                    budgetReason: String?, isolatedStateDir: Bool, skipRequested: Bool = false) {
            self.sessionID = sessionID
            self.role = role
            self.existingKey = existingKey
            self.siblingKey = siblingKey
            self.pinnedCommand = pinnedCommand
            self.keepShellOpen = keepShellOpen
            self.shell = shell
            self.zmxPath = zmxPath
            self.budgetReason = budgetReason
            self.isolatedStateDir = isolatedStateDir
            self.skipRequested = skipRequested
        }
    }

    /// ⚠️ The wrapper is never `zmx attach <key> <command>`. A command given to zmx is used INSTEAD of
    /// creating a shell, so it becomes the session's whole process: it exits, the session ends, the client
    /// exits, and the pane has nothing left in it. `keepShellOpen` therefore hands zmx a shell and puts the
    /// command inside it.
    ///
    /// ⚠️ A pane is left unwrapped rather than given the key its SIBLING owns. `closePrimaryPane` promotes
    /// the split survivor with its `-right` key into the main slot and clears `zmxSplitKey`, so the next ⌘D
    /// derives `-right` again — two panes on one daemon, mirroring each other, and an `exit` in either ending
    /// the agent in both. The row keeps one persistent pane and gets a plain shell for the second, which is
    /// the same safe outcome every other rejection here produces.
    public static func decide(_ inputs: Inputs) -> Decision {
        let isSplit = inputs.role == .right
        if inputs.isolatedStateDir { return .unwrapped(reason: "AGTERM_STATE_DIR is set") }
        if inputs.skipRequested { return .unwrapped(reason: "AGTERM_ZMX_SKIP is set") }
        guard let zmx = inputs.zmxPath, !zmx.isEmpty else { return .unwrapped(reason: "zmx is not installed") }
        if let budgetReason = inputs.budgetReason { return .unwrapped(reason: budgetReason) }

        let key = adoptedKey(inputs) ?? ZmxSessionKey.key(sessionID: inputs.sessionID, isSplit: isSplit)
        guard key != inputs.siblingKey else {
            return .unwrapped(reason: "the row's other pane already owns \(key)")
        }
        let pinned = inputs.pinnedCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pinned.isEmpty else {
            return .wrap(command: CommandRestore.shellQuotedLine([zmx, "attach", key]), key: key)
        }
        guard inputs.keepShellOpen else {
            return .unwrapped(reason: "a pinned command replaces the login shell the hook would run in")
        }
        // one level of quoting per level of shell: the script is quoted as one argument here, and the `exec`
        // tail is quoted again inside it because that string is what zmx's `-lc` shell evaluates.
        //
        // Separated by a NEWLINE, not `; ` — a pinned command ending in a `#` comment would swallow the tail
        // on one line and the row would vanish exactly as it does without the flag.
        let script = "\(pinned)\nexec \(CommandRestore.shellQuotedLine([inputs.shell, "-l"]))"
        return .wrap(command: CommandRestore.shellQuotedLine([zmx, "attach", key, inputs.shell, "-lc", script]),
                     key: key)
    }

    /// The key this pane already owns, when it is one this session could have produced. A key naming another
    /// session is refused rather than adopted: two rows attached to one daemon mirror each other, and a close
    /// of either ends the agent in both.
    private static func adoptedKey(_ inputs: Inputs) -> String? {
        guard let existing = inputs.existingKey,
              ZmxSessionKey.parse(existing)?.sessionID == inputs.sessionID else { return nil }
        return existing
    }
}
