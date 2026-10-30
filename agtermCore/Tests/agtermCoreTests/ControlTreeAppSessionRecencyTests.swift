import Foundation
import Testing
@testable import agtermCore

/// The tree field `appSessionRecency`: the app-wide visit list narrowed to what each open window would let a
/// user step onto, with the active window's active session dropped, and its wire shape.
@MainActor
final class ControlTreeAppSessionRecencyTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tree-recency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Window `A` (`a0` selected, `a1`) and frontmost window `B` (`b0`, `b1` selected), with the visit list
    /// `b0, a1, b1, a0`.
    private struct Fixture {
        let library: WindowLibrary
        let a: UUID
        let b: UUID
        let a0: UUID
        let a1: UUID
        let b0: UUID
        let b1: UUID

        func entry(_ session: UUID, _ window: UUID) -> ControlRecentSession {
            ControlRecentSession(session: session.uuidString, window: window.uuidString)
        }
    }

    private func makeFixture() throws -> Fixture {
        let library = WindowLibrary(directory: directory)
        let a = try #require(library.activeWindowID)
        let b = library.newWindow(name: "B").id
        var ids: [UUID] = []
        for window in [a, b] {
            let store = try #require(library.store(for: window))
            let workspace = try #require(store.workspaces.first)
            _ = store.addSession(toWorkspace: workspace.id, cwd: "/second", select: false)
            ids += store.workspaces.flatMap(\.sessions).map(\.id)
        }
        let fixture = Fixture(library: library, a: a, b: b, a0: ids[0], a1: ids[1], b0: ids[2], b1: ids[3])
        try #require(library.store(for: b)).selectSession(fixture.b1)
        library.appRecency.push(fixture.a1)
        library.appRecency.push(fixture.b0)
        #expect(library.appRecency.items == [fixture.b0, fixture.a1, fixture.b1, fixture.a0])
        return fixture
    }

    // MARK: - controlAppSessionRecency

    @Test func entriesKeepListOrderWithTheirWindows() throws {
        let f = try makeFixture()
        #expect(f.library.controlAppSessionRecency() == [f.entry(f.b0, f.b), f.entry(f.a1, f.a), f.entry(f.a0, f.a)])
    }

    @Test func theActiveWindowsActiveSessionIsLeftOutButAnotherWindowsSelectionStays() throws {
        let f = try makeFixture()
        let sessions = f.library.controlAppSessionRecency()?.map(\.session) ?? []
        #expect(!sessions.contains(f.b1.uuidString))
        #expect(try #require(f.library.store(for: f.a)).selectedSessionID == f.a0)
        #expect(sessions.contains(f.a0.uuidString))
    }

    @Test func aSessionInAClosedWindowIsLeftOut() throws {
        let f = try makeFixture()
        f.library.closeWindow(f.a)
        #expect(f.library.appRecency.items.contains(f.a1))
        #expect(f.library.controlAppSessionRecency() == [f.entry(f.b0, f.b)])
    }

    @Test func aSessionHiddenByParkedHidingIsLeftOut() throws {
        let f = try makeFixture()
        let store = try #require(f.library.store(for: f.a))
        store.setParked(true, forSession: f.a1)
        store.hideParked = true
        #expect(f.library.controlAppSessionRecency() == [f.entry(f.b0, f.b), f.entry(f.a0, f.a)])
    }

    @Test func aSessionHiddenByTheFocusFilterIsLeftOut() throws {
        let f = try makeFixture()
        let store = try #require(f.library.store(for: f.a))
        let other = store.addWorkspace(name: "other")
        let shown = try #require(store.addSession(toWorkspace: other.id, cwd: "/other", select: false))
        f.library.appRecency.push(shown.id)
        store.setFocusedWorkspace(other.id)
        #expect(f.library.controlAppSessionRecency() == [f.entry(shown.id, f.a), f.entry(f.b0, f.b)])
    }

    @Test func aPendingCloseSessionIsLeftOutWhileItsIDStays() throws {
        let f = try makeFixture()
        let store = try #require(f.library.store(for: f.a))
        defer { store.finalizeAllPendingCloses() }
        #expect(store.softCloseSession(f.a1, grace: 60))
        #expect(f.library.appRecency.items.contains(f.a1))
        #expect(f.library.controlAppSessionRecency() == [f.entry(f.b0, f.b), f.entry(f.a0, f.a)])
    }

    @Test func anEmptyResultIsNil() throws {
        let library = WindowLibrary(directory: directory)
        let active = try #require(library.activeStore?.activeSession)
        #expect(library.appRecency.items == [active.id])
        #expect(library.controlAppSessionRecency() == nil)
    }

    // MARK: - Wire

    @Test func aSetFieldEncodesAsAnArrayOfObjects() throws {
        let entry = ControlRecentSession(session: UUID().uuidString, window: UUID().uuidString)
        let tree = ControlTree(workspaces: []).with(appSessionRecency: [entry])
        let data = try JSONEncoder().encode(tree)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let field = try #require(object["appSessionRecency"] as? [[String: String]])
        #expect(field == [["session": entry.session, "window": entry.window]])
        #expect(try JSONDecoder().decode(ControlTree.self, from: data) == tree)
    }

    @Test func aNilFieldOmitsTheKey() throws {
        let tree = ControlTree(workspaces: []).with(appSessionRecency: nil)
        let json = String(decoding: try JSONEncoder().encode(tree), as: UTF8.self)
        #expect(!json.contains("appSessionRecency"))
    }

    @Test func anOlderTreeWithoutTheKeyDecodesWithNil() throws {
        let tree = try JSONDecoder().decode(ControlTree.self, from: Data(#"{"workspaces":[],"idleMs":5}"#.utf8))
        #expect(tree.appSessionRecency == nil)
        #expect(tree.idleMs == 5)
    }
}
