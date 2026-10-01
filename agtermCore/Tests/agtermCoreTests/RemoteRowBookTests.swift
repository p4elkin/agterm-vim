import Foundation
import Testing
@testable import agtermCore

@MainActor
final class RemoteRowBookTests {
    private let directory: URL
    private let originLeft = UUID()
    private let originRight = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-remote-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func origin(_ transport: RemoteTransport = .ssh) -> RemoteBinding.Origin {
        RemoteBinding.Origin(host: "buildbox",
            endpoint: ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/remote-zmx"),
            sessionName: "remote-session", transport: transport)
    }

    private func row(in store: AppStore, origin: RemoteBinding.Origin?, version: Int? = 1) throws -> Session {
        let ws = try #require(store.workspaces.first)
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "remote-id",
            daemonsByLocalPane: [session.paneIdentity: ZmxSupport.daemonName(for: originLeft)],
            presentationVersion: version, origin: origin), forSession: session.id)
        return session
    }

    private func record(_ transport: RemoteTransport = .ssh, version: Int? = 1) throws -> RemoteRowBook.Record {
        let library = WindowLibrary(directory: directory)
        let window = try #require(library.windows.first)
        let store = try #require(library.store(for: window.id))
        let session = try row(in: store, origin: origin(transport), version: version)
        let workspace = try #require(store.workspaces.first?.id)
        return try #require(RemoteRowBook.Record(session: session, windowID: window.id, workspaceID: workspace, position: 1))
    }

    @Test(arguments: [RemoteTransport.ssh, .mosh(server: "/opt/mosh-server", client: "/opt/mosh"),
                      .mosh(server: nil, client: nil)])
    func recordsRoundTripEndpointTransportAndPlacement(transport: RemoteTransport) throws {
        let saved = try record(transport)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(RemoteRowBook.Record.self, from: data) == saved)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] == nil)
        #expect(object["initialCommand"] == nil)
    }

    @Test(arguments: [Int?.none, .some(1)])
    func aRestoredBindingKeepsThePresentationVersionAndTransport(version: Int?) throws {
        let saved = try record(.mosh(server: "/opt/mosh-server", client: "/opt/mosh"), version: version)
        let book = RemoteRowBook(directory: directory)
        try book.save([saved])
        let restored = try #require(book.load().first)
        let local = UUID()
        let binding = restored.binding(daemonsByLocalPane: [local: try #require(restored.daemonsByPane[.left])])
        #expect(binding.presentationVersion == version)
        #expect(binding.remoteSessionID == saved.remoteSessionID)
        #expect(binding.origin == origin(saved.transport))
        #expect(binding.localPane(forRemote: originLeft) == local)
    }

    @Test func aRowWithoutAnOriginProducesNoRecord() throws {
        let library = WindowLibrary(directory: directory)
        let window = try #require(library.windows.first)
        let store = try #require(library.store(for: window.id))
        let session = try row(in: store, origin: nil)
        let workspace = try #require(store.workspaces.first?.id)
        #expect(RemoteRowBook.Record(session: session, windowID: window.id, workspaceID: workspace, position: 1) == nil)
        #expect(RemoteRowBook.records(from: library, previous: []).isEmpty)
    }

    @Test func walkingTheLibrarySavesOnlyRemoteRowsAtTheirActualPosition() throws {
        let library = WindowLibrary(directory: directory)
        let window = try #require(library.windows.first)
        let store = try #require(library.store(for: window.id))
        let workspace = try #require(store.workspaces.first)
        let local = try #require(workspace.sessions.first)
        let remote = try row(in: store, origin: origin())
        remote.initialCommand = "must not be saved"
        let records = RemoteRowBook.records(from: library, previous: [])
        let saved = try #require(records.first)
        #expect(records.count == 1)
        #expect(local.remoteHost == nil)
        #expect(saved.windowID == window.id)
        #expect(saved.workspaceID == workspace.id)
        #expect(saved.position == 1)
        #expect(saved.remoteSessionID == "remote-id")
        #expect(saved.host == "buildbox")
        #expect(saved.daemonsByPane == [.left: ZmxSupport.daemonName(for: originLeft)])
    }

    @Test func aHiddenSplitAndItsAxisAreSavedByCurrentPaneRole() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let session = try row(in: store, origin: origin())
        store.toggleSplit(session.id)
        let split = try #require(session.splitPaneIdentity)
        store.addRemotePane(local: split, daemon: ZmxSupport.daemonName(for: originRight), forSession: session.id)
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        #expect(store.swapPanes(session.id) == nil)
        store.setSplitVisibility(session.id, shown: true, axis: .topBottom)
        store.setSplitVisibility(session.id, shown: false)
        let saved = try #require(RemoteRowBook.records(from: library, previous: []).first)
        #expect(saved.daemonsByPane == [.left: ZmxSupport.daemonName(for: originRight),
                                       .right: ZmxSupport.daemonName(for: originLeft)])
        #expect(saved.splitAxis == .topBottom)
    }

    @Test func closingAReopenableWindowKeepsItsPreviousRowsUnchanged() throws {
        let library = WindowLibrary(directory: directory)
        let window = library.newWindow(name: "remote")
        let store = try #require(library.store(for: window.id))
        _ = try row(in: store, origin: origin(.mosh(server: nil, client: nil)))
        let previous = RemoteRowBook.records(from: library, previous: [])
        library.closeWindow(window.id)
        #expect(library.store(for: window.id) == nil)
        #expect(library.windows.contains { $0.id == window.id })
        #expect(RemoteRowBook.records(from: library, previous: previous) == previous)
    }

    @Test func removingAWindowDropsItsPreviousRows() throws {
        let library = WindowLibrary(directory: directory)
        let window = library.newWindow(name: "remote")
        _ = try row(in: try #require(library.store(for: window.id)), origin: origin())
        let previous = RemoteRowBook.records(from: library, previous: [])
        #expect(previous.count == 1)
        library.removeWindow(window.id)
        #expect(RemoteRowBook.records(from: library, previous: previous).isEmpty)
    }

    @Test func closingARowInAnOpenWindowDropsItsPreviousRecord() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let session = try row(in: store, origin: origin())
        let previous = RemoteRowBook.records(from: library, previous: [])
        store.closeSession(session.id)
        #expect(RemoteRowBook.records(from: library, previous: previous).isEmpty)
    }

    @Test(arguments: ["", "-oProxyCommand=id", "bad host", "bad\nhost"])
    func loadDropsInvalidHostsWithoutDiscardingOtherRows(host: String) throws {
        let valid = try record()
        var invalid = valid
        invalid.host = host
        let book = RemoteRowBook(directory: directory)
        try book.save([invalid, valid])
        #expect(book.load() == [valid])
    }

    @Test(arguments: ["", "agterm-notes", "agterm-fffffffffffffffffffffffffffffffg", "daemon\n"])
    func loadDropsInvalidDaemonNames(daemon: String) throws {
        var invalid = try record()
        invalid.daemonsByPane[.left] = daemon
        let book = RemoteRowBook(directory: directory)
        try book.save([invalid])
        #expect(book.load().isEmpty)
    }

    @Test(arguments: ["", "/x y", "/bin/mosh;id", "$(id)", "~/.bin/mosh", "/bin/mosh\n"])
    func loadValidatesBothMoshPathsAfterCodableDecode(path: String) throws {
        let valid = try record(.mosh(server: nil, client: nil))
        var server = valid, client = valid
        server.transport = .mosh(server: path, client: nil)
        client.transport = .mosh(server: nil, client: path)
        let book = RemoteRowBook(directory: directory)
        try book.save([server, client, valid])
        #expect(book.load() == [valid])
    }

    @Test func missingAndCorruptFilesReadAsEmptyAndWritesReplaceAtomically() throws {
        let state = directory.appendingPathComponent("isolated-state")
        let book = RemoteRowBook(directory: state)
        #expect(book.fileURL == state.appendingPathComponent("remote-rows.json"))
        #expect(book.load().isEmpty)
        let first = try record()
        try book.save([first])
        #expect(book.load() == [first])
        var second = first
        second.transport = .mosh(server: nil, client: nil)
        try book.save([second])
        #expect(try JSONDecoder().decode([RemoteRowBook.Record].self, from: Data(contentsOf: book.fileURL)) == [second])
        #expect(try FileManager.default.contentsOfDirectory(atPath: state.path) == ["remote-rows.json"])
        try Data("broken".utf8).write(to: book.fileURL)
        #expect(book.load().isEmpty)
    }
    @Test func restorePlanKeepsSavedPlacementAndFiltersOtherWindows() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let window = try #require(library.activeWindowID)
        let workspace = try #require(store.workspaces.first?.id)
        var first = try record(), second = first, other = first
        first.windowID = window; first.workspaceID = workspace; first.position = 1
        second.windowID = window; second.workspaceID = workspace; second.position = 3
        other.windowID = UUID()
        let count = store.workspaces.flatMap(\.sessions).count
        let selected = store.selectedSessionID
        let plan = RemoteRowBook.restorePlan(records: [second, other, first], windowID: window, store: store)
        #expect(plan.map(\.record) == [first, second])
        #expect(plan.map(\.workspaceID) == [workspace, workspace])
        #expect(plan.map(\.position) == [1, 3])
        #expect(store.workspaces.flatMap(\.sessions).count == count)
        #expect(store.selectedSessionID == selected)
    }

    @Test func missingWorkspacesAppendToTheCurrentWorkspaceAfterPlannedRows() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let window = try #require(library.activeWindowID)
        let current = store.addWorkspace(name: "current")
        _ = store.addSession(toWorkspace: current.id, cwd: "/tmp")
        _ = store.addSession(toWorkspace: current.id, cwd: "/tmp")
        var known = try record(), missing = known, another = known
        known.windowID = window; known.workspaceID = current.id; known.position = 1
        missing.windowID = window; missing.workspaceID = UUID(); missing.position = 99
        another.windowID = window; another.workspaceID = UUID(); another.position = 0
        let plan = RemoteRowBook.restorePlan(records: [missing, known, another], windowID: window, store: store)
        #expect(plan.map(\.record) == [known, missing, another])
        #expect(plan.map(\.workspaceID) == [current.id, current.id, current.id])
        #expect(plan.map(\.position) == [1, 3, 4])
    }

    @Test func anEmptyStoreCannotPlaceARecordAndInvalidRecordsAreSkipped() throws {
        var saved = try record()
        let empty = makeStore()
        #expect(RemoteRowBook.restorePlan(records: [saved], windowID: saved.windowID, store: empty).isEmpty)
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        saved.windowID = try #require(library.activeWindowID)
        saved.host = "-bad"
        #expect(RemoteRowBook.restorePlan(records: [saved], windowID: saved.windowID, store: store).isEmpty)
    }

    private func softClose(_ path: String, in store: AppStore, first: Session, second: Session) -> Bool {
        switch path {
        case "session": return store.softCloseSession(first.id, grace: 60)
        case "batch": return store.softCloseSessions([first.id, second.id], grace: 60)
        default:
            guard let workspace = store.workspace(forSession: first.id) else { return false }
            _ = store.addWorkspace(name: "staying")
            return store.softRemoveWorkspace(workspace.id, grace: 60)
        }
    }

    @Test(arguments: ["session", "batch", "workspace"])
    func softClosedRowsRemainSavedWithoutPreviousRecordsUntilFinalization(path: String) throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        defer { store.finalizeAllPendingCloses() }
        let first = try row(in: store, origin: origin())
        let second = try row(in: store, origin: origin(.mosh(server: nil, client: nil)))
        let before = RemoteRowBook.records(from: library, previous: [])
        #expect(softClose(path, in: store, first: first, second: second))
        #expect(store.session(withID: first.id) == nil)
        let retained = RemoteRowBook.records(from: library, previous: [])
        #expect(retained == before)
        let book = RemoteRowBook(directory: directory)
        try book.save(retained)
        #expect(book.load() == before)
        store.finalizeAllPendingCloses()
        let after = RemoteRowBook.records(from: library, previous: retained)
        #expect(after.count == (path == "session" ? 1 : 0))
        if path == "session" {
            #expect(after.first?.transport == .mosh(server: nil, client: nil))
            #expect(after.first?.position == 1)
        }
    }

    @Test(arguments: ["session", "batch", "workspace"])
    func undoReturnsEachSavedRowExactlyOnce(path: String) throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        defer { store.finalizeAllPendingCloses() }
        let first = try row(in: store, origin: origin())
        let second = try row(in: store, origin: origin(.mosh(server: nil, client: nil)))
        let before = RemoteRowBook.records(from: library, previous: [])
        #expect(softClose(path, in: store, first: first, second: second))
        let during = RemoteRowBook.records(from: library, previous: before)
        #expect(store.undoPendingClose())
        #expect(store.pendingCloseMembers().isEmpty)
        let after = RemoteRowBook.records(from: library, previous: during)
        #expect(after == before)
        #expect(after.count == 2)
    }

    @Test func pendingRowsUseTheirCurrentBindingRatherThanAStalePreviousRecord() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        defer { store.finalizeAllPendingCloses() }
        let session = try row(in: store, origin: origin())
        let before = RemoteRowBook.records(from: library, previous: [])
        var previous = before
        previous[0].host = "old-host"
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(RemoteRowBook.records(from: library, previous: previous) == before)
    }

    @Test func savingDuringGraceKeepsVisibleRowsInTheirOriginalPositions() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        defer { store.finalizeAllPendingCloses() }
        let first = try row(in: store, origin: origin())
        let workspace = try #require(store.workspace(forSession: first.id))
        _ = store.addSession(toWorkspace: workspace.id, cwd: "/tmp")
        _ = try row(in: store, origin: origin(.mosh(server: nil, client: nil)))
        let before = RemoteRowBook.records(from: library, previous: [])
        #expect(before.map(\.position) == [1, 3])
        #expect(store.softCloseSession(first.id, grace: 60))
        #expect(RemoteRowBook.records(from: library, previous: []) == before)
    }

    @Test func separatePendingClosesKeepTheOrderBeforeBothCloses() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        defer { store.finalizeAllPendingCloses() }
        let first = try row(in: store, origin: origin())
        let workspace = try #require(store.workspace(forSession: first.id))
        _ = store.addSession(toWorkspace: workspace.id, cwd: "/tmp")
        let last = try row(in: store, origin: origin(.mosh(server: nil, client: nil)))
        let before = RemoteRowBook.records(from: library, previous: [])
        #expect(store.softCloseSession(first.id, grace: 60))
        #expect(store.softCloseSession(last.id, grace: 60))
        #expect(RemoteRowBook.records(from: library, previous: []) == before)
    }

}
