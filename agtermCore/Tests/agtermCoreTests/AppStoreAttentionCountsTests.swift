import Foundation
import Testing
@testable import agtermCore

/// Kept out of `AppStoreTests` because that file is already at its 2000-line limit.
@MainActor
struct AppStoreAttentionCountsTests {
    @Test func attentionCountsSpanEveryWorkspaceInTheWindow() throws {
        let store = makeStore()
        let first = store.addWorkspace(name: "first")
        let second = store.addWorkspace(name: "second")
        let blocked = try #require(store.addSession(toWorkspace: first.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: second.id, cwd: "/b"))
        let completed = try #require(store.addSession(toWorkspace: second.id, cwd: "/c"))
        let idle = try #require(store.addSession(toWorkspace: second.id, cwd: "/d"))
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: blocked.id)
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: completed.id)
        store.setAgentIndicator(AgentIndicator(status: .idle), forSession: idle.id)

        #expect(store.attentionCounts == AttentionCounts(blocked: 1, active: 1, completed: 1))
    }

    @Test func attentionCountsUnseenIsTheSelectedSessionAlone() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let selected = try #require(store.addSession(toWorkspace: ws.id, cwd: "/selected"))
        let other = try #require(store.addSession(toWorkspace: ws.id, cwd: "/other"))
        _ = store.selectSession(selected.id) // selecting clears unseen, so the counts are set after it
        selected.unseenCount = 4
        other.unseenCount = 7

        #expect(store.attentionCounts.unseen == 4)
    }

    @Test func attentionCountsReadsZeroUnseenWithNoSelection() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        session.unseenCount = 3
        _ = store.selectSession(nil)

        #expect(store.attentionCounts.unseen == 0)
        #expect(store.attentionCounts.isEmpty)
    }
}
