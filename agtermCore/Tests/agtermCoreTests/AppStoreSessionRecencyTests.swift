import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreSessionRecencyTests {
    @Test func controlTreeReportsSessionRecencyWithoutTheActiveSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.selectSession(b.id)

        #expect(store.controlTree().sessionRecency == [a.id.uuidString])
    }

    @Test func controlTreeSessionRecencyIsMostRecentFirst() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.selectSession(a.id)
        store.selectSession(b.id)
        store.selectSession(c.id)

        #expect(store.controlTree().sessionRecency == [b.id.uuidString, a.id.uuidString])
    }

    @Test func controlTreeOmitsSessionRecencyWithNowhereToJumpBackTo() {
        let store = makeStore()
        #expect(store.controlTree().sessionRecency == nil)
        let ws = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectSession(only.id)

        #expect(store.controlTree().sessionRecency == nil)
    }

    // pins the projection itself: swapping `navigableRecentSessions` for the raw `recentSessions` still
    // passes every other case here.
    @Test func controlTreeSessionRecencyNarrowsToTheVisibleScope() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!
        let d = store.addSession(toWorkspace: personal.id, cwd: "/d", select: false)!
        store.selectSession(d.id)
        store.selectSession(a.id)
        store.selectSession(c.id)
        store.selectSession(b.id)

        store.setFocusedWorkspace(personal.id)

        #expect(store.controlTree().sessionRecency == [d.id.uuidString])
    }

    @Test func controlTreeSessionRecencyDropsAClosedSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.selectSession(a.id)
        store.selectSession(b.id)
        store.selectSession(c.id)
        store.closeSession(a.id)

        #expect(store.controlTree().sessionRecency == [b.id.uuidString])
    }

    /// The encoded key, which neither the model tests nor the `ControlTree` round-trip assert together.
    @Test func sessionRecencyReachesTheEncodedTreeAndIsOmittedWithoutIt() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.selectSession(b.id)

        let encode = { (tree: ControlTree) throws -> String in
            let data = try JSONEncoder().encode(ControlResponse(ok: true, result: ControlResult(tree: tree)))
            return String(decoding: data, as: UTF8.self)
        }
        let populated = try encode(store.controlTree())
        #expect(populated.contains("\"sessionRecency\":[\"\(a.id.uuidString)\"]"))

        store.closeSession(a.id)
        #expect(!(try encode(store.controlTree())).contains("sessionRecency"))
    }
}
