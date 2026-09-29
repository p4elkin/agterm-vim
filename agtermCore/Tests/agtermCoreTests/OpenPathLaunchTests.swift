import Foundation
import Testing
@testable import agtermCore

struct OpenPathLaunchTests {
    static let sessionID = UUID(uuidString: "DACF59D6-6401-410B-A19D-94BF884702A5")!

    @Test func unsplitPaneTargetsTheSessionSlot() {
        let args = OpenPathLaunch.arguments(path: "docs/x.md", line: nil, cwd: "/repo", sessionID: Self.sessionID,
                                            pane: .left, isSplit: false, socket: "/tmp/a.sock")
        #expect(args == ["--cwd", "/repo", "--target", Self.sessionID.uuidString,
                         "--socket", "/tmp/a.sock", "--", "docs/x.md"])
    }

    @Test func splitRightPaneCarriesPaneAndLine() {
        let args = OpenPathLaunch.arguments(path: "src/a.swift", line: 12, cwd: "/right", sessionID: Self.sessionID,
                                            pane: .right, isSplit: true, socket: "/tmp/a.sock")
        #expect(args == ["--cwd", "/right", "--target", Self.sessionID.uuidString, "--socket", "/tmp/a.sock",
                         "--pane", "right", "--line", "12", "--", "src/a.swift"])
    }

    @Test func scratchNeverNamesAPane() {
        let args = OpenPathLaunch.arguments(path: "-x/a.md", line: nil, cwd: "/r", sessionID: Self.sessionID,
                                            pane: .scratch, isSplit: true, socket: nil)
        #expect(!args.contains("--pane"))
        #expect(!args.contains("--socket"))
        #expect(args.suffix(2) == ["--", "-x/a.md"])
    }
}
