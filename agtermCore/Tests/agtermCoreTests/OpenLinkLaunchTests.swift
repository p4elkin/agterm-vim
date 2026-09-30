import Foundation
import Testing
@testable import agtermCore

@MainActor
struct OpenLinkLaunchTests {
    @Test(arguments: ["http://x.test/a", "https://x.test/browse/AB-1", "HTTPS://x.test/"])
    func webLinksGoToTheHelper(raw: String) throws {
        #expect(OpenLinkLaunch.handles(try #require(URL(string: raw))))
    }

    @Test(arguments: ["mailto:a@b.test", "ftp://x.test/f"])
    func mailAndFtpStayWithTheSystemOpener(raw: String) throws {
        #expect(!OpenLinkLaunch.handles(try #require(URL(string: raw))))
    }

    @Test func unsplitPaneTargetsTheSessionSlot() throws {
        let session = Session(initialCwd: "/repo")
        let url = try #require(URL(string: "https://x.test/-/merge_requests/1"))
        let args = OpenLinkLaunch.arguments(url: url, session: session, pane: .left, socket: "/tmp/a.sock")
        #expect(args == ["--target", session.id.uuidString, "--socket", "/tmp/a.sock",
                         "--", "https://x.test/-/merge_requests/1"])
    }

    @Test func splitRightPaneIsNamed() throws {
        let session = Session(initialCwd: "/left")
        session.isSplit = true
        let url = try #require(URL(string: "https://x.test/browse/AB-1"))
        let args = OpenLinkLaunch.arguments(url: url, session: session, pane: .right, socket: nil)
        #expect(args == ["--target", session.id.uuidString, "--pane", "right", "--", "https://x.test/browse/AB-1"])
        #expect(!args.contains("--cwd"))
    }
}
