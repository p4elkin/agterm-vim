import Foundation
import Testing
@testable import agtermCore

struct RebasedViewTests {
    @Test(arguments: [("a/b.kt", "a/b.kt", 0), ("a/b.kt:42", "a/b.kt", 42), ("a:b.kt:7", "a:b.kt", 7), ("a:b.kt", "a:b.kt", 0)])
    func parsesFileTargets(spec: String, path: String, line: Int) throws {
        let target = try #require(RebasedFileTarget(spec: spec))
        #expect(target.path == path)
        #expect(target.line == line)
    }

    @Test(arguments: ["", "a/b.kt:", "a/b.kt:0", "a/b.kt:9999999999999999999999", "a\tb.kt", "a\nb.kt", "a\rb.kt"])
    func refusesInvalidFileTargets(spec: String) {
        #expect(RebasedFileTarget(spec: spec) == nil)
    }

    @Test(arguments: [("A..", true), ("A...B", true), ("A..B", false), ("A..HEAD", false)])
    func workingTreeDoesNotSilentlyIgnoreAHead(spec: String, accepted: Bool) {
        #expect((RebasedView(diff: spec, workingTree: true) != nil) == accepted)
        #expect(RebasedView(diff: spec, workingTree: false) != nil)
    }

    @Test(arguments: [false, true])
    func diffBridgeArgumentsKeepTheDirectoryLast(pane: Bool) throws {
        let view = try #require(RebasedView(diff: "A...B", workingTree: true))
        let holder = pane ? "pane" : "session"
        #expect(view.bridgeVerb == "diff")
        #expect(view.bridgeArgument(request: "req", project: "/repo\twith tab", pane: pane)
                == "req\tA\tB\t1\t1\t\(holder)\t/repo\twith tab")
        #expect(view.kind == .workingTree)
        #expect(view.target == "A...B")
    }

    @Test(arguments: [false, true])
    func fileBridgeArgumentsPutTheLineBeforeThePath(pane: Bool) {
        let view = RebasedView.file(path: "/repo/a:b.kt", line: 7)
        #expect(view.bridgeVerb == "openFile")
        #expect(view.bridgeArgument(request: "req", project: "/repo\twith tab", pane: pane)
                == "req\t7\t/repo/a:b.kt\t/repo\twith tab")
        #expect(view.kind == .file)
        #expect(view.target == "/repo/a:b.kt")
    }

    @Test func aNewRequestClearsThePreviousResultAndRejectsLateEvents() throws {
        var request = RebasedViewRequest(view: .file(path: "/repo/a", line: 0))
        let oldID = request.id
        request.sent()
        let transitionAccepted1 = request.apply(event: .opened("/repo/a"), request: oldID)
        #expect(transitionAccepted1)
        #expect(request.state == .opened)
        #expect(request.detail == "/repo/a")
        let view = try #require(RebasedView(diff: "A.."))
        let currentID = request.issue(view)
        #expect(currentID != oldID)
        #expect(request.id == currentID)
        #expect(request.state == .queued)
        #expect(request.detail == nil)
        #expect(request.kind == .diff)
        #expect(request.target == "A..HEAD")
        let transitionAccepted2 = !request.apply(event: .failed("old failure"), request: oldID)
        #expect(transitionAccepted2)
        #expect(request.state == .queued)
        request.sent()
        let transitionAccepted3 = request.apply(event: .opened("0"), request: currentID)
        #expect(transitionAccepted3)
        #expect(request.state == .opened)
        #expect(request.detail == "0")
    }

    @Test func aViewFailureStoresItsReason() {
        var request = RebasedViewRequest(view: .file(path: "/missing", line: 0))
        request.sent()
        let transitionAccepted4 = request.apply(event: .failed("file not found"), request: request.id)
        #expect(transitionAccepted4)
        #expect(request.state == .failed)
        #expect(request.detail == "file not found")
    }

    @Test func onlyTheCurrentSentRequestCanTimeOut() {
        var request = RebasedViewRequest(view: .file(path: "/repo/a", line: 0))
        let transitionAccepted5 = !request.timedOut(request: request.id)
        #expect(transitionAccepted5)
        #expect(request.state == .queued)
        request.sent()
        #expect(request.state == .sent)
        let transitionAccepted6 = !request.timedOut(request: UUID().uuidString)
        #expect(transitionAccepted6)
        let transitionAccepted7 = request.timedOut(request: request.id)
        #expect(transitionAccepted7)
        #expect(request.state == .failed)
        #expect(request.detail == "view request timed out")
        let transitionAccepted8 = !request.timedOut(request: request.id)
        #expect(transitionAccepted8)
    }

    @Test func anOpenedRequestCannotTimeOut() {
        var request = RebasedViewRequest(view: .file(path: "/repo/a", line: 0))
        request.sent()
        let transitionAccepted9 = request.apply(event: .opened("/repo/a"), request: request.id)
        #expect(transitionAccepted9)
        let transitionAccepted10 = !request.timedOut(request: request.id)
        #expect(transitionAccepted10)
        #expect(request.state == .opened)
    }

    @Test func anOverlayKeepsItsViewAndCapturedOnCloseValue() {
        let onClose = RebasedOnClose(command: "/bin/flush --final", cwd: "/repo", environment: ["AGTERM_PANE": "left"])
        var overlay = RebasedOverlay(project: "/repo", view: RebasedViewRequest(view: .file(path: "/repo/a", line: 3)), onClose: onClose)
        let requestID = overlay.view?.id
        overlay.project = "/mirror"
        overlay.source = "host:/repo"
        #expect(overlay.view?.id == requestID)
        #expect(overlay.onClose == onClose)
        #expect(overlay.onClose?.command == "/bin/flush --final")
        #expect(overlay.onClose?.cwd == "/repo")
        #expect(overlay.onClose?.environment == ["AGTERM_PANE": "left"])
    }
}
