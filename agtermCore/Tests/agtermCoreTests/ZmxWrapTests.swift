import Foundation
import Testing
@testable import agtermCore

struct ZmxWrapTests {
    private let id = UUID(uuidString: "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F")!
    private let zmx = "/opt/homebrew/bin/zmx"
    private let shell = "/bin/zsh"

    private func inputs(role: ZmxSessionKey.Role = .left, existingKey: String? = nil, siblingKey: String? = nil,
                        command: String? = nil, keepShellOpen: Bool = false,
                        zmxPath: String? = "/opt/homebrew/bin/zmx", budgetReason: String? = nil,
                        isolated: Bool = false, skip: Bool = false) -> ZmxWrap.Inputs {
        ZmxWrap.Inputs(sessionID: id, role: role, existingKey: existingKey, siblingKey: siblingKey,
                       pinnedCommand: command, keepShellOpen: keepShellOpen, shell: shell, zmxPath: zmxPath,
                       budgetReason: budgetReason, isolatedStateDir: isolated, skipRequested: skip)
    }

    private func wrapped(_ decision: ZmxWrap.Decision) -> (command: String, key: String)? {
        guard case let .wrap(command, key) = decision else { return nil }
        return (command, key)
    }

    private func unwrappedReason(_ decision: ZmxWrap.Decision) -> String? {
        guard case let .unwrapped(reason) = decision else { return nil }
        return reason
    }

    /// Split a `shellQuotedLine` back into argv the way one level of shell evaluation would, so a test can
    /// assert what zmx actually receives rather than how it was spelled.
    private func argv(of line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuote = false
        var started = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                inQuote.toggle()
                started = true
            } else if c == "\\", !inQuote, i + 1 < chars.count {
                current.append(chars[i + 1])
                started = true
                i += 1
            } else if c == " ", !inQuote {
                if started { out.append(current) }
                current = ""
                started = false
            } else {
                current.append(c)
                started = true
            }
            i += 1
        }
        if started { out.append(current) }
        return out
    }

    @Test func plainRowIsWrapped() {
        let result = wrapped(ZmxWrap.decide(inputs()))
        #expect(result?.key == "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left")
        #expect(result?.command == "'\(zmx)' 'attach' '6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left'")
        #expect(argv(of: result?.command ?? "") == [zmx, "attach", "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left"])
    }

    @Test func splitPaneGetsTheRightKey() {
        let result = wrapped(ZmxWrap.decide(inputs(role: .right)))
        #expect(result?.key == "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-right")
        #expect(argv(of: result?.command ?? "").last == result?.key)
    }

    /// Scratch and overlay are not "never wrapped" by a rule that could be edited away — the role type has no
    /// case for them, so their factories cannot ask for a key. What stays testable is that the reaper still
    /// recognizes a daemon the outside tooling left under one of those names.
    @Test func scratchAndOverlayAreNotRolesAtAllButStayReapable() {
        #expect(ZmxSessionKey.Role.allCases.map(\.rawValue) == ["left", "right"])
        #expect(ZmxSessionKey.isOwned("\(id.uuidString)-scratch"))
        #expect(ZmxSessionKey.isOwned("\(id.uuidString)-overlay"))
        #expect(ZmxSessionKey.parse("\(id.uuidString)-scratch") == nil)
    }

    @Test func isolatedStateDirWrapsNothing() {
        #expect(unwrappedReason(ZmxWrap.decide(inputs(isolated: true)))?.contains("AGTERM_STATE_DIR") == true)
        #expect(unwrappedReason(ZmxWrap.decide(inputs(command: "claude", keepShellOpen: true, isolated: true)))?
            .contains("AGTERM_STATE_DIR") == true)
    }

    /// The escape hatch the retiring zprofile hook used to own. It has to keep working once the hook is gone,
    /// and it must beat every later gate, including a row that asked to keep its shell open.
    @Test func skipRequestedWrapsNothing() {
        #expect(unwrappedReason(ZmxWrap.decide(inputs(skip: true)))?.contains("AGTERM_ZMX_SKIP") == true)
        #expect(unwrappedReason(ZmxWrap.decide(inputs(role: .right, skip: true)))?
            .contains("AGTERM_ZMX_SKIP") == true)
        #expect(unwrappedReason(ZmxWrap.decide(inputs(command: "claude", keepShellOpen: true, skip: true)))?
            .contains("AGTERM_ZMX_SKIP") == true)
        #expect(wrapped(ZmxWrap.decide(inputs(skip: false))) != nil)
    }

    @Test func missingBinaryFallsBackToAPlainShell() {
        #expect(unwrappedReason(ZmxWrap.decide(inputs(zmxPath: nil)))?.contains("zmx") == true)
        #expect(unwrappedReason(ZmxWrap.decide(inputs(zmxPath: "")))?.contains("zmx") == true)
    }

    @Test func overBudgetSocketPathFallsBackAndKeepsTheReason() {
        let reason = "zmx socket path in /tmp/very-long needs 128 bytes, over the 101-byte budget"
        #expect(ZmxWrap.decide(inputs(budgetReason: reason)) == .unwrapped(reason: reason))
        #expect(ZmxWrap.decide(inputs(command: "claude", keepShellOpen: true, budgetReason: reason))
                == .unwrapped(reason: reason))
    }

    /// ⚠️ The promoted-survivor case: the pane is addressed as `left` but is a client of the `-right` session.
    @Test func aRecordedKeyIsAdoptedInsteadOfDerivedFromTheRole() {
        let promoted = "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-right"
        let result = wrapped(ZmxWrap.decide(inputs(role: .left, existingKey: promoted)))
        #expect(result?.key == promoted)
        #expect(argv(of: result?.command ?? "") == [zmx, "attach", promoted])
    }

    /// ⚠️ The re-split after a promotion: the main pane holds `-right`, so deriving `-right` for the new
    /// split would put both panes on one daemon and let an `exit` in either end the agent in both.
    @Test func aKeyTheSiblingPaneOwnsIsNeverDerived() {
        let promoted = "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-right"
        let reason = unwrappedReason(ZmxWrap.decide(inputs(role: .right, siblingKey: promoted)))
        #expect(reason?.contains(promoted) == true)
        #expect(wrapped(ZmxWrap.decide(inputs(role: .right, siblingKey: promoted))) == nil)
    }

    /// The same collision arriving from a snapshot that already holds it, so a row persisted by an older
    /// build cannot bring two panes back onto one daemon.
    @Test func aRecordedKeyTheSiblingPaneOwnsIsRefusedToo() {
        let shared = "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-right"
        #expect(wrapped(ZmxWrap.decide(inputs(role: .left, existingKey: shared, siblingKey: shared))) == nil)
        #expect(wrapped(ZmxWrap.decide(inputs(role: .right, existingKey: shared, siblingKey: shared))) == nil)
    }

    @Test func aSiblingKeyOfTheOtherRoleLeavesTheWrapAlone() {
        let left = "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left"
        #expect(wrapped(ZmxWrap.decide(inputs(role: .right, siblingKey: left)))?.key
                == "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-right")
    }

    @Test func aRecordedKeyOfAnotherSessionIsRefused() {
        let foreign = "\(UUID().uuidString)-left"
        for bogus in [foreign, "not-a-key", ""] {
            #expect(wrapped(ZmxWrap.decide(inputs(existingKey: bogus)))?.key
                    == "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left")
        }
    }

    @Test func plainCommandRowKeepsItsOwnCommand() {
        guard case let .unwrapped(reason) = ZmxWrap.decide(inputs(command: "ssh host")) else {
            Issue.record("a --command row without keep-shell-open must not be wrapped")
            return
        }
        #expect(reason.contains("pinned command"))
    }

    @Test func blankPinnedCommandCountsAsAPlainRow() {
        for blank in ["", "   ", "\n"] {
            #expect(wrapped(ZmxWrap.decide(inputs(command: blank)))?.command
                    == "'\(zmx)' 'attach' '6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left'")
        }
    }

    @Test func keepShellOpenRunsTheCommandInsideZmxShell() {
        let result = wrapped(ZmxWrap.decide(inputs(command: "claude", keepShellOpen: true)))
        let parts = argv(of: result?.command ?? "")
        // never `zmx attach <key> <command>`: a command given to zmx REPLACES its shell and takes the
        // session down with it when it exits.
        #expect(parts == [zmx, "attach", "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left", shell, "-lc",
                          "claude\nexec '\(shell)' '-l'"])
    }

    /// A `; ` separator puts the tail inside a trailing comment and the row vanishes silently, which is the
    /// exact failure `--keep-shell-open` exists to prevent.
    @Test func aCommandEndingInACommentStillReachesTheExecTail() {
        let parts = argv(of: wrapped(ZmxWrap.decide(inputs(command: "claude # notes", keepShellOpen: true)))?
            .command ?? "")
        #expect(parts.last?.hasSuffix("exec '\(shell)' '-l'") == true)
        #expect(parts.last?.contains("\n") == true)
    }

    @Test func keepShellOpenIgnoredWithoutACommand() {
        #expect(wrapped(ZmxWrap.decide(inputs(keepShellOpen: true)))?.command
                == "'\(zmx)' 'attach' '6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left'")
    }

    @Test func commandSurvivesExactlyOneShellEvaluation() {
        let command = #"printf "%s" "$HOME" `id -u` 'it'"'"'s' && echo \done"#
        let result = wrapped(ZmxWrap.decide(inputs(command: command, keepShellOpen: true)))
        let parts = argv(of: result?.command ?? "")
        // the outer level yields the script verbatim: nothing in the command was expanded or re-escaped on
        // the way through, so the `-lc` shell is the first and only thing that evaluates it.
        #expect(parts.count == 6)
        #expect(parts[5] == "\(command)\nexec '\(shell)' '-l'")
        #expect(parts[5].hasPrefix(command))
    }

    @Test func shellPathWithASpaceStaysOneArgument() {
        let spaced = "/opt/my shells/zsh"
        let decision = ZmxWrap.decide(ZmxWrap.Inputs(sessionID: id, role: .left, existingKey: nil,
                                                     siblingKey: nil, pinnedCommand: "claude",
                                                     keepShellOpen: true, shell: spaced, zmxPath: zmx,
                                                     budgetReason: nil, isolatedStateDir: false))
        let parts = argv(of: wrapped(decision)?.command ?? "")
        #expect(parts.count == 6)
        #expect(parts[3] == spaced)
        #expect(parts[5] == "claude\nexec '\(spaced)' '-l'")
    }

    @Test func zmxPathWithASpaceStaysOneArgument() {
        let spaced = "/Applications/My Tools/zmx"
        let parts = argv(of: wrapped(ZmxWrap.decide(inputs(zmxPath: spaced)))?.command ?? "")
        #expect(parts == [spaced, "attach", "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F-left"])
    }

    @Test func keyIsTheOneTheReaperParsesBack() {
        for role in [ZmxSessionKey.Role.left, .right] {
            let key = wrapped(ZmxWrap.decide(inputs(role: role)))?.key ?? ""
            #expect(ZmxSessionKey.parse(key) == ZmxSessionKey.Parsed(sessionID: id, role: role))
        }
    }
}
