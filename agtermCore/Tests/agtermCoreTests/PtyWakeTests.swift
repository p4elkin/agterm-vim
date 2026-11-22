import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PtyWakeTests {
    private let store: AppStore
    private let row: Session
    private let split: UUID

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-pty-wake-\(UUID().uuidString)")
        store = AppStore(persistence: PersistenceStore(directory: directory))
        let workspace = store.workspaces.first ?? store.addWorkspace(name: "work")
        row = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/srv", remoteHost: "box"))
        split = UUID()
        row.hasSplit = true
        row.isSplit = true
        row.splitPaneIdentity = split
        row.asleep = true
    }

    private func pane(_ cmd: Command, _ args: ControlArgs? = nil, surface: TerminalZoomSurface? = nil) -> PtyWake.Pane? {
        PtyWake.pane(of: ControlRequest(cmd: cmd, args: args), on: row, surface: surface)
    }

    private var left: PtyWake.Pane { PtyWake.Pane(role: .left, identity: row.paneIdentity) }
    private var right: PtyWake.Pane { PtyWake.Pane(role: .right, identity: split) }

    @Test func anAwakeRowNeedsNoWake() {
        row.asleep = false
        for cmd in PtyWake.commands.union([.sessionText]) {
            #expect(pane(cmd, ControlArgs(text: "ls")) == nil, "\(cmd)")
        }
    }

    @Test func eachCommandDrivesThePaneItAddresses() {
        #expect(pane(.sessionType, ControlArgs(text: "ls")) == left)
        #expect(pane(.sessionType, ControlArgs(text: "ls", pane: "bottom")) == right)
        #expect(pane(.sessionPaste, ControlArgs(pane: "right")) == right)
        #expect(pane(.sessionSelectAll) == left)
        #expect(pane(.sessionCopy) == left)
        #expect(pane(.sessionLead, ControlArgs(pane: "split")) == right)
        for font in [Command.fontInc, .fontDec, .fontReset] {
            #expect(pane(font) == left)
            #expect(pane(font, ControlArgs(pane: "right")) == right)
        }
        #expect(pane(.surfaceCursor, surface: .split) == right)
        #expect(pane(.surfaceCursor, surface: .primary) == left)
    }

    @Test func aTokenNamesThePaneOfAnAsleepRow() {
        #expect(pane(.sessionType, ControlArgs(text: "ls", paneID: split.uuidString)) == right)
        #expect(pane(.surfaceCursor, ControlArgs(paneID: row.paneIdentity.uuidString)) == left)
        #expect(pane(.sessionText, ControlArgs(paneID: split.uuidString)) == right)
        #expect(pane(.sessionType, ControlArgs(text: "ls", pane: "left", paneID: UUID().uuidString)) == left,
                "an unknown token beside a role takes the role, as paneAddress does")
    }

    @Test func aRequestItsArmRefusesWakesNothing() {
        #expect(pane(.sessionType) == nil, "no text")
        #expect(pane(.sessionType, ControlArgs(text: "a\u{0}b")) == nil, "a NUL")
        #expect(pane(.sessionType, ControlArgs(text: "ls", pane: "middle")) == nil)
        #expect(pane(.sessionType, ControlArgs(text: "ls", paneID: UUID().uuidString)) == nil)
        #expect(pane(.surfaceCursor, ControlArgs(paneID: UUID().uuidString)) == nil)
        #expect(pane(.sessionSearch, ControlArgs(to: "close")) == nil)
        #expect(pane(.sessionSearch, ControlArgs(to: "sideways")) == nil)
    }

    @Test func theScratchAndAMissingSplitWakeNothing() {
        #expect(pane(.sessionType, ControlArgs(text: "ls", pane: "scratch")) == nil)
        #expect(pane(.sessionText, ControlArgs(pane: "scratch")) == nil)
        #expect(pane(.surfaceCursor, surface: .scratch) == nil)
        #expect(pane(.surfaceCursor, surface: .overlay) == nil)
        row.hasSplit = false
        row.isSplit = false
        #expect(pane(.sessionPaste, ControlArgs(pane: "right")) == nil)
        #expect(pane(.fontInc, ControlArgs(pane: "right")) == nil)
    }

    @Test func aHiddenSplitNoSleepReleasedIsReadFromTheOriginButNotWoken() {
        row.isSplit = false
        #expect(pane(.sessionType, ControlArgs(text: "ls", pane: "right")) == nil)
        #expect(pane(.surfaceCursor, surface: .split) == nil)
        #expect(pane(.sessionText, ControlArgs(pane: "right")) == right)
        row.splitReleasedAsleep = true
        #expect(pane(.sessionType, ControlArgs(text: "ls", pane: "right")) == right, "the wake builds a pane a sleep released")
    }

    @Test func searchAndAnUnnamedTextFollowTheFocusedPane() {
        #expect(pane(.sessionSearch, ControlArgs(text: "err")) == left)
        #expect(pane(.sessionText) == left)
        row.splitFocused = true
        #expect(pane(.sessionSearch, ControlArgs(text: "err", to: "next")) == right)
        #expect(pane(.sessionText) == right)
        #expect(pane(.sessionText, ControlArgs(pane: "left")) == left)
    }

    @Test func noCommandOutsideTheListWakes() {
        #expect(pane(.sessionRestart, ControlArgs(pane: "left")) == nil, "forwarded to the origin")
        #expect(pane(.tree) == nil)
        #expect(pane(.sessionOverlayOpen, ControlArgs(command: "top")) == nil)
    }
}
