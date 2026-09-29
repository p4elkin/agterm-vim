import Foundation
import Testing
@testable import agtermCore

@MainActor
struct OpenPathLaunchTests {
    @Test func unsplitPaneTargetsTheSessionSlot() {
        let session = Session(initialCwd: "/repo")
        let args = OpenPathLaunch.arguments(path: "docs/x.md", line: nil, session: session, pane: .left,
                                            socket: "/tmp/a.sock")
        #expect(args == ["--cwd", "/repo", "--target", session.id.uuidString,
                         "--socket", "/tmp/a.sock", "--", "docs/x.md"])
    }

    @Test func splitRightPaneCarriesPaneCwdAndLine() {
        let session = Session(initialCwd: "/left")
        session.isSplit = true
        session.splitCwd = "/right"
        let args = OpenPathLaunch.arguments(path: "src/a.swift", line: 12, session: session, pane: .right,
                                            socket: "/tmp/a.sock")
        #expect(args == ["--cwd", "/right", "--target", session.id.uuidString, "--socket", "/tmp/a.sock",
                         "--pane", "right", "--line", "12", "--", "src/a.swift"])
    }

    @Test func scratchNeverNamesAPane() {
        let session = Session(initialCwd: "/r")
        session.isSplit = true
        let args = OpenPathLaunch.arguments(path: "-x/a.md", line: nil, session: session, pane: .scratch,
                                            socket: nil)
        #expect(!args.contains("--pane"))
        #expect(!args.contains("--socket"))
        #expect(args.suffix(2) == ["--", "-x/a.md"])
    }
}
