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
