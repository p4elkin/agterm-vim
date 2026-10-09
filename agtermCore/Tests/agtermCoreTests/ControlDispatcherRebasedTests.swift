import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherRebasedTests {
    @Test(arguments: [ControlArgs(file: "/repo/a", project: "/other"), ControlArgs(diff: "A..", onClose: "/bin/flush"),
                      ControlArgs(pane: "left", diff: "A.."), ControlArgs(rebased: true, diff: "A..")])
    func showRefusesOpenOnlyFlags(args: ControlArgs) async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionRebasedShow, args: args))
        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func showRoutesTheWorkingTreeViewToTheAddressedSession() async throws {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .sessionRebasedShow, target: "s", args: ControlArgs(window: "w", diff: "HEAD..", workingTree: true))
        _ = await ControlDispatcher(actions: actions).dispatch(request)
        #expect(actions.calls == [.rebasedShow(target: "s", window: "w", view: try #require(RebasedView(diff: "HEAD..", workingTree: true)))])
    }

    @Test func showRoutesAFileAndItsLine() async {
        let actions = MockControlActions()
        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionRebasedShow, args: ControlArgs(file: "/repo/a.kt:3")))
        #expect(actions.calls == [.rebasedShow(target: nil, window: nil, view: .file(path: "/repo/a.kt", line: 3))])
    }

    @Test(arguments: [ControlArgs(), ControlArgs(diff: "A..", file: "/repo/a"), ControlArgs(workingTree: true),
                      ControlArgs(diff: "A..B", workingTree: true), ControlArgs(file: "a\tb.kt"), ControlArgs(diff: "-p")])
    func showRefusesMissingOrInvalidViews(args: ControlArgs) async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionRebasedShow, args: args))
        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func toggleRoutesTheTargetAndWindow() async {
        let actions = MockControlActions()
        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionRebasedToggle, target: "s", args: ControlArgs(window: "w")))
        #expect(actions.calls == [.rebasedToggle(target: "s", window: "w")])
    }
}
