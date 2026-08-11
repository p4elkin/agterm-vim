import Foundation
import Testing
@testable import agtermCore

struct ZmxWrapTests {
    private let id = UUID(uuidString: "6C8E2C3A-6C1D-4F1E-9E9C-0A1B2C3D4E5F")!
    private let zmx = "/opt/homebrew/bin/zmx"
    private let shell = "/bin/zsh"

    private func inputs(role: ZmxSessionKey.Role = .left, command: String? = nil, keepShellOpen: Bool = false,
                        zmxPath: String? = "/opt/homebrew/bin/zmx", budgetReason: String? = nil,
                        isolated: Bool = false) -> ZmxWrap.Inputs {
        ZmxWrap.Inputs(sessionID: id, role: role, pinnedCommand: command, keepShellOpen: keepShellOpen,
                       shell: shell, zmxPath: zmxPath, budgetReason: budgetReason, isolatedStateDir: isolated)
    }

    private func wrapped(_ decision: ZmxWrap.Decision) -> (command: String, key: String)? {
        guard case let .wrap(command, key) = decision else { return nil }
        return (command, key)
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

    @Test func scratchAndOverlayAreNeverWrapped() {
        for role in [ZmxSessionKey.Role.scratch, .overlay] {
            #expect(ZmxWrap.decide(inputs(role: role)) == .unwrapped(reason: "a \(role.rawValue) surface is never zmx-backed"))
        }
    }

    @Test func isolatedStateDirWrapsNothing() {
        #expect(ZmxWrap.decide(inputs(isolated: true)) == .unwrapped(reason: "AGTERM_STATE_DIR is set"))
        #expect(ZmxWrap.decide(inputs(command: "claude", keepShellOpen: true, isolated: true))
                == .unwrapped(reason: "AGTERM_STATE_DIR is set"))
    }

    @Test func missingBinaryFallsBackToAPlainShell() {
        #expect(ZmxWrap.decide(inputs(zmxPath: nil)) == .unwrapped(reason: "zmx is not installed"))
        #expect(ZmxWrap.decide(inputs(zmxPath: "")) == .unwrapped(reason: "zmx is not installed"))
    }

    @Test func overBudgetSocketPathFallsBackAndKeepsTheReason() {
        let reason = "zmx socket path in /tmp/very-long needs 128 bytes, over the 101-byte budget"
        #expect(ZmxWrap.decide(inputs(budgetReason: reason)) == .unwrapped(reason: reason))
        #expect(ZmxWrap.decide(inputs(command: "claude", keepShellOpen: true, budgetReason: reason))
                == .unwrapped(reason: reason))
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
                          "claude; exec '\(shell)' '-l'"])
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
        #expect(parts[5] == "\(command); exec '\(shell)' '-l'")
        #expect(parts[5].hasPrefix(command))
    }

    @Test func shellPathWithASpaceStaysOneArgument() {
        let spaced = "/opt/my shells/zsh"
        let decision = ZmxWrap.decide(ZmxWrap.Inputs(sessionID: id, role: .left, pinnedCommand: "claude",
                                                     keepShellOpen: true, shell: spaced, zmxPath: zmx,
                                                     budgetReason: nil, isolatedStateDir: false))
        let parts = argv(of: wrapped(decision)?.command ?? "")
        #expect(parts.count == 6)
        #expect(parts[3] == spaced)
        #expect(parts[5] == "claude; exec '\(spaced)' '-l'")
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
