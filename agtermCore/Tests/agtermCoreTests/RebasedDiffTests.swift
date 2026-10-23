import Foundation
import Testing
@testable import agtermCore

struct RebasedDiffTests {
    @Test(arguments: [
        ("main..feature", "main", "feature", false, "main..feature"),
        ("main...HEAD", "main", "HEAD", true, "main...HEAD"),
        ("origin/main...", "origin/main", "HEAD", true, "origin/main...HEAD"),
        ("..topic", "HEAD", "topic", false, "HEAD..topic"),
        ("HEAD~3", "HEAD~3", "HEAD", false, "HEAD~3..HEAD"),
        ("abc123^..abc123", "abc123^", "abc123", false, "abc123^..abc123"),
    ])
    func parsesARange(_ spec: String, _ base: String, _ head: String, _ mergeBase: Bool, _ normalized: String) throws {
        let diff = try #require(RebasedDiff(spec: spec))
        #expect(diff == RebasedDiff(base: base, head: head, mergeBase: mergeBase))
        #expect(diff.spec == normalized)
    }

    @Test(arguments: ["", "..", "...", "a..b..c", "a....b", "-p", "a..--output=x", "a b", "a\tb", "a\nb", ".hidden..b"])
    func refusesARangeGitWouldMisread(_ spec: String) {
        #expect(RebasedDiff(spec: spec) == nil)
    }

    @Test func theBridgeArgumentPutsTheProjectLast() throws {
        let diff = try #require(RebasedDiff(spec: "main...HEAD"))
        #expect(diff.bridgeArgument(project: "/repo\twith tab") == "main\tHEAD\t1\t/repo\twith tab")
        #expect(try #require(RebasedDiff(spec: "a..b")).bridgeArgument(project: "/r") == "a\tb\t0\t/r")
    }

    @MainActor @Test func theOverlayNodeReportsTheRequestedRange() throws {
        var overlay = RebasedOverlay(project: "/repo", state: .shown)
        #expect(overlay.controlNode.diff == nil)
        overlay.diff = RebasedDiff(spec: "main...HEAD")
        #expect(overlay.controlNode == ControlRebasedOverlayNode(project: "/repo", state: "shown", diff: "main...HEAD", hidden: false))
    }
}
