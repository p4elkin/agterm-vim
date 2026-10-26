import Foundation
import Testing
@testable import agtermCore

/// The library's app-wide visit list: a push counts only from the frontmost window, a real close or a window
/// delete forgets, and a launch with no `session-recency.json` seeds from the open windows' own lists.
@MainActor
final class WindowLibraryAppRecencyTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-app-recency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var recencyFile: URL { AppSessionRecencyPersistence(directory: directory).fileURL }

    /// Window `A` from the launch and window `B` from `newWindow`, each with a second session, `B` frontmost.
    private func makeTwoWindows() throws -> (WindowLibrary, a: UUID, b: UUID) {
        let library = WindowLibrary(directory: directory)
        let a = try #require(library.activeWindowID)
        let b = library.newWindow(name: "B").id
        for id in [a, b] {
            let store = try #require(library.store(for: id))
            let workspace = try #require(store.workspaces.first)
            _ = store.addSession(toWorkspace: workspace.id, cwd: "/second", select: false)
        }
        return (library, a, b)
    }

    private func sessions(_ library: WindowLibrary, _ id: UUID) throws -> [Session] {
        try #require(library.store(for: id)).workspaces.flatMap(\.sessions)
    }

    // MARK: - Visits

    @Test func aSelectionInTheFrontmostWindowIsAVisit() throws {
        let (library, _, b) = try makeTwoWindows()
        let target = try sessions(library, b)[1]
        try #require(library.store(for: b)).selectSession(target.id)
        #expect(library.appRecency.items.first == target.id)
    }

    @Test func aSelectionInABackgroundWindowMovesOnlyItsOwnList() throws {
        let (library, a, _) = try makeTwoWindows()
        let store = try #require(library.store(for: a))
        let target = try sessions(library, a)[1]
        store.selectSession(target.id)
        #expect(store.sessionRecency.items.first == target.id)
        #expect(!library.appRecency.items.contains(target.id))
    }

    @Test func aWindowCountsOnceItIsFrontmost() throws {
        let (library, a, _) = try makeTwoWindows()
        library.frontmostWindowID = a
        let target = try sessions(library, a)[1]
        try #require(library.store(for: a)).selectSession(target.id)
        #expect(library.appRecency.items.first == target.id)
    }

    @Test func aDwellThatEndsBehindAnotherWindowIsNotAVisit() throws {
        let (library, a, b) = try makeTwoWindows()
        let store = try #require(library.store(for: b))
        store.recencyDwell = 20
        let target = try sessions(library, b)[1]
        store.selectSession(target.id)
        library.frontmostWindowID = a
        store.recencyDwellDebouncer.flush()
        #expect(store.sessionRecency.items.first == target.id)
        #expect(!library.appRecency.items.contains(target.id))
    }

    // MARK: - Close reselection

    @Test(arguments: [nil, 20.0] as [TimeInterval?])
    func closingInTheFrontmostWindowVisitsTheReselection(dwell: TimeInterval?) throws {
        let (library, _, b) = try makeTwoWindows()
        let store = try #require(library.store(for: b))
        let closing = try sessions(library, b)[1]
        store.selectSession(closing.id)
        store.recencyDwell = dwell

        store.closeSession(closing.id)
        let reselected = try #require(store.selectedSessionID)
        if dwell != nil {
            #expect(library.appRecency.items.first != reselected)
            store.recencyDwellDebouncer.flush()
        }

        #expect(library.appRecency.items.first == reselected)
    }

    @Test func closingInABackgroundWindowVisitsNothing() throws {
        let (library, a, _) = try makeTwoWindows()
        let store = try #require(library.store(for: a))
        let closing = try sessions(library, a)[1]
        store.selectSession(closing.id)
        let before = library.appRecency.items

        store.closeSession(closing.id)

        #expect(library.appRecency.items == before.filter { $0 != closing.id })
    }

    // MARK: - Removal

    @Test func closingASessionForgetsIt() throws {
        let (library, _, b) = try makeTwoWindows()
        let store = try #require(library.store(for: b))
        let closing = try sessions(library, b)[1]
        store.selectSession(closing.id)
        #expect(library.appRecency.items.contains(closing.id))

        store.closeSession(closing.id)

        #expect(!library.appRecency.items.contains(closing.id))
    }

    @Test func removingAnOpenWindowForgetsAllItsSessions() throws {
        let (library, a, _) = try makeTwoWindows()
        library.frontmostWindowID = a
        let doomed = try sessions(library, a)
        for session in doomed { try #require(library.store(for: a)).selectSession(session.id) }
        #expect(doomed.allSatisfy { library.appRecency.items.contains($0.id) })

        library.removeWindow(a)

        #expect(doomed.allSatisfy { !library.appRecency.items.contains($0.id) })
    }

    @Test func closingAWindowKeepsItsSessionsAndRemovingItLaterForgetsThem() throws {
        let (library, a, b) = try makeTwoWindows()
        library.frontmostWindowID = a
        let kept = try sessions(library, a)
        for session in kept { try #require(library.store(for: a)).selectSession(session.id) }
        library.frontmostWindowID = b

        library.closeWindow(a)
        #expect(kept.allSatisfy { library.appRecency.items.contains($0.id) })

        library.removeWindow(a)
        #expect(kept.allSatisfy { !library.appRecency.items.contains($0.id) })
    }

    // MARK: - Moves

    /// The launch window `S`, frontmost, with `home` (`h`, `x`) and `project` (`p0`, `p1`); visits `h`, then `x`.
    private func makeMoveSource() throws -> (WindowLibrary, source: UUID, project: Workspace) {
        let library = WindowLibrary(directory: directory)
        let source = try #require(library.activeWindowID)
        let store = try #require(library.store(for: source))
        let home = try #require(store.workspaces.first)
        let x = try #require(store.addSession(toWorkspace: home.id, cwd: "/x", select: false))
        let project = store.addWorkspace(name: "project")
        _ = store.addSession(toWorkspace: project.id, cwd: "/p0", select: false)
        _ = store.addSession(toWorkspace: project.id, cwd: "/p1", select: false)
        library.frontmostWindowID = source
        store.selectSession(home.sessions[0].id)
        store.selectSession(x.id)
        return (library, source, try #require(store.workspaces.first { $0.id == project.id }))
    }

    /// `open` and `loaded` hand the source frontmost back, as it is when a move starts from it.
    private func moveDestination(_ kind: MoveKind, _ library: WindowLibrary, source: UUID) -> TransferDestination {
        guard kind != .new else { return .new }
        let id = library.newWindow(name: "dest").id
        if kind == .loaded { library.closeWindow(id) }
        library.frontmostWindowID = source
        return .window(id)
    }

    @Test(arguments: MoveKind.allCases, [nil, 20.0] as [TimeInterval?])
    func aMovedSessionIsAVisitOnceTheDwellEndsInTheDestination(_ kind: MoveKind, dwell: TimeInterval?) throws {
        let (library, source, project) = try makeMoveSource()
        let moved = project.sessions[0]
        let sourceStore = try #require(library.store(for: source))
        let destination = moveDestination(kind, library, source: source)
        sourceStore.recencyDwell = dwell
        if kind == .open, case .window(let id) = destination { try #require(library.store(for: id)).recencyDwell = dwell }

        let result = try library.transferWorkspace(project.id, from: source, to: destination).get()

        let store = try #require(library.store(for: result.windowID))
        #expect(store.recencyDwell == dwell)
        if dwell != nil {
            #expect(library.appRecency.items.first != moved.id)
            store.recencyDwellDebouncer.flush()
        }
        #expect(library.appRecency.items.first == moved.id)
    }

    @Test(arguments: MoveKind.allCases)
    func leavingAMovedSessionBeforeTheDwellEndsKeepsItsPlace(_ kind: MoveKind) throws {
        let (library, source, project) = try makeMoveSource()
        let (moved, other) = (project.sessions[0], project.sessions[1])
        let sourceStore = try #require(library.store(for: source))
        let destination = moveDestination(kind, library, source: source)
        sourceStore.selectSession(moved.id)
        sourceStore.selectSession(sourceStore.workspaces[0].sessions[0].id)
        sourceStore.recencyDwell = 20
        if kind == .open, case .window(let id) = destination { try #require(library.store(for: id)).recencyDwell = 20 }
        let before = library.appRecency.items
        #expect(before.firstIndex(of: moved.id) == 1)

        let result = try library.transferWorkspace(project.id, from: source, to: destination).get()
        let store = try #require(library.store(for: result.windowID))
        store.selectSession(other.id)
        store.recencyDwellDebouncer.flush()

        #expect(library.appRecency.items.first == other.id)
        #expect(library.appRecency.items.filter { $0 != other.id } == before)
    }

    @Test(arguments: [FallbackCase.immediate, .dwellFlushed, .dwellFlushedWithTheSourceFrontmost])
    func theSourceFallbackIsNeverAVisit(_ fallback: FallbackCase) throws {
        let (library, source, project) = try makeMoveSource()
        let sourceStore = try #require(library.store(for: source))
        let x = sourceStore.workspaces[0].sessions[1]
        sourceStore.selectSession(project.sessions[0].id)
        let before = library.appRecency.items
        #expect(before.firstIndex(of: x.id) == 1)
        if fallback != .immediate { sourceStore.recencyDwell = 20 }

        _ = try library.transferWorkspace(project.id, from: source, to: .new).get()
        #expect(sourceStore.selectedSessionID == x.id)
        if fallback == .dwellFlushedWithTheSourceFrontmost { library.frontmostWindowID = source }
        sourceStore.recencyDwellDebouncer.flush()

        #expect(sourceStore.sessionRecency.items.first == x.id)
        #expect(library.appRecency.items.firstIndex(of: x.id) == 1)
    }

    @Test func aLastWorkspaceMoveKeepsTheMovedSessionsInTheList() throws {
        let library = WindowLibrary(directory: directory)
        let source = try #require(library.activeWindowID)
        let store = try #require(library.store(for: source))
        let only = try #require(store.workspaces.first)
        let second = try #require(store.addSession(toWorkspace: only.id, cwd: "/second", select: false))
        library.frontmostWindowID = source
        store.selectSession(second.id)
        let visited = library.appRecency.items
        #expect(visited.contains(second.id))

        let result = try library.transferWorkspace(only.id, from: source, to: .new).get()

        #expect(result.removedSourceWindow == source)
        #expect(visited.allSatisfy(library.appRecency.items.contains))
    }

    // MARK: - Launch

    @Test func aLaunchWithNoFileSeedsFrontmostFirst() throws {
        let (first, a, b) = try makeTwoWindows()
        try #require(first.store(for: a)).selectSession(try sessions(first, a)[1].id)
        try #require(first.store(for: b)).selectSession(try sessions(first, b)[1].id)
        first.frontmostWindowID = b
        _ = first.saveIndex()
        #expect(first.saveAllOpenChecked())
        try FileManager.default.removeItem(at: recencyFile)

        let relaunched = WindowLibrary(directory: directory)

        let storeA = try #require(relaunched.store(for: a))
        let storeB = try #require(relaunched.store(for: b))
        #expect(!storeA.sessionRecency.items.isEmpty && !storeB.sessionRecency.items.isEmpty)
        #expect(relaunched.appRecency.items == storeB.sessionRecency.items + storeA.sessionRecency.items)
        #expect(FileManager.default.fileExists(atPath: recencyFile.path))
    }

    @Test func aRelaunchLoadsTheSavedOrderWithoutSeedingOrPromotingSelections() throws {
        let (first, a, b) = try makeTwoWindows()
        let inB = try sessions(first, b)
        try #require(first.store(for: b)).selectSession(inB[1].id)
        // a background selection: A's own list leads with it, the app-wide list does not
        let inA = try sessions(first, a)
        try #require(first.store(for: a)).selectSession(inA[1].id)
        try #require(first.store(for: a)).selectSession(inA[0].id)
        let saved = first.appRecency.items
        #expect(!saved.contains(inB[0].id))
        #expect(saved.first == inB[1].id)
        first.frontmostWindowID = a
        _ = first.saveIndex()
        #expect(first.saveAllOpenChecked())

        let relaunched = WindowLibrary(directory: directory)

        #expect(try #require(relaunched.store(for: a)).selectedSessionID == inA[0].id)
        #expect(relaunched.appRecency.items == saved)
    }
}

enum MoveKind: CaseIterable, Sendable {
    case new, open, loaded
}

enum FallbackCase: Sendable {
    case immediate, dwellFlushed, dwellFlushedWithTheSourceFrontmost
}
