import Foundation
import Testing
@testable import agtermCore

// Its own suite file beside `ControlDispatcherMarkTests` for the same reason: `ControlDispatcherTests.swift`
// sits at the 2000-line test cap. Shares its `MockControlActions`.
@MainActor
struct ControlDispatcherBookmarkTests {
    @Test func addRoutesTargetTurnAndPrompt() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionBookmarkAddResponse = ControlResponse(ok: true, result: ControlResult(count: 4))

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionBookmarkAdd, target: "session",
            args: ControlArgs(text: "fix the flaky test", window: "win", turn: 4)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(count: 4)))
        #expect(actions.calls == [.sessionBookmarkAdd(target: "session", window: "win", turn: 4,
                                                      prompt: "fix the flaky test")])
    }

    @Test func addWithoutTurnOrPromptRoutesDefaults() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkAdd, target: "session"))

        #expect(actions.calls == [.sessionBookmarkAdd(target: "session", window: nil, turn: nil, prompt: "")])
    }

    @Test func nonPositiveTurnIsRejectedBeforeRouting() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        for cmd: Command in [.sessionBookmarkAdd, .sessionBookmarkGo, .sessionBookmarkRemove] {
            let response = await dispatcher.dispatch(ControlRequest(cmd: cmd, target: "s",
                                                                    args: ControlArgs(turn: 0)))
            #expect(response?.ok == false)
            #expect(response?.error == "--turn must be greater than 0")
        }
        #expect(actions.calls.isEmpty)
    }

    @Test func listRoutesTargetAndAll() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkList, target: "session"))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkList,
                                                     args: ControlArgs(all: true)))

        #expect(actions.calls == [
            .sessionBookmarkList(target: "session", window: nil, all: false),
            .sessionBookmarkList(target: nil, window: nil, all: true)
        ])
    }

    @Test func goFiresTheExistingSearchPathWithTheNeedle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionSearchResponse = ControlResponse(ok: true,
                                                            result: ControlResult(text: "1 of 1", count: 1))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkGo, target: "session",
                                                                args: ControlArgs(turn: 7)))

        #expect(response?.result?.count == 1)
        #expect(actions.calls == [.sessionSearch(target: "session", window: nil,
                                                 text: TurnMark.needle(for: 7), to: nil)])
    }

    @Test func goOnABookmarkWhoseMarkIsGoneAnswersZeroMatches() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        // scrollback did not survive, so the search finds nothing — still ok, the caller shows the stored text
        actions.nextSessionSearchResponse = ControlResponse(ok: true,
                                                            result: ControlResult(text: "0 of 0", count: 0))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkGo, target: "session",
                                                                args: ControlArgs(turn: 3)))

        #expect(response?.ok == true)
        #expect(response?.result?.count == 0)
    }

    @Test func goRequiresTurn() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkGo, target: "session"))

        #expect(response?.ok == false)
        #expect(response?.error == "session.bookmark.go requires --turn")
        #expect(actions.calls.isEmpty)
    }

    @Test func removeRoutesAndRequiresTurn() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkRemove, target: "s"))
        #expect(missing?.error == "session.bookmark.remove requires --turn")

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionBookmarkRemove, target: "s",
                                                     args: ControlArgs(turn: 2)))
        #expect(actions.calls == [.sessionBookmarkRemove(target: "s", window: nil, turn: 2)])
    }

    @Test func treeReportsBookmarkCountAndOmitsZero() {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let bookmarked = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        let bare = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/b"))
        let center = BookmarkCenter()
        center.add(sessionID: bookmarked.id, turn: 1, prompt: "p")
        center.add(sessionID: bookmarked.id, turn: 2, prompt: "q")

        // `bookmarkCount` is fork-only, so it lives on the paneForeground overload alone; that one has no
        // default for its first closure.
        let tree = store.controlTree(paneForeground: { _ in nil }, bookmarkCount: { session in
            let count = center.count(sessionID: session.id)
            return count > 0 ? count : nil
        })

        let sessions = tree.workspaces[0].sessions
        #expect(sessions.first { $0.id == bookmarked.id.uuidString }?.bookmarks == 2)
        #expect(sessions.first { $0.id == bare.id.uuidString }?.bookmarks == nil)
    }
}
