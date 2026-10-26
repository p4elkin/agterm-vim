import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryTransferTests {
    private let directory: URL
    private var finalized: [UUID] = []
    private var events: [ControlEvent] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-library-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("windows").path)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - workspace moves

    @Test func aWorkspaceMovesToANewWindowHoldingOnlyIt() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let sessions = project.sessions

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new).get()

        let store = try #require(fixture.library.store(for: result.windowID))
        #expect(store.workspaces.map(\.id) == [project.id])
        #expect(store.workspaces[0].sessions.map(\.id) == sessions.map(\.id))
        #expect(zip(store.workspaces[0].sessions, sessions).allSatisfy { $0 === $1 })
        #expect(store.workspaces.flatMap(\.sessions).count == 2)
        #expect(fixture.library.windowName(for: result.windowID) == "project")
        #expect(!result.needsOpen)
        #expect(fixture.library.frontmostWindowID == result.windowID)
        let index = try readIndex()
        #expect(index.frontmost == result.windowID)
        #expect(index.windows.last == WindowEntry(id: result.windowID, name: "project", isOpen: true))
        #expect(try windowFile(result.windowID).workspaces.map(\.id) == [project.id])
        #expect(fixture.store.workspaces.allSatisfy { $0.id != project.id })
        #expect(try windowFile(fixture.source).workspaces.allSatisfy { $0.id != project.id })
    }

    @Test func aWindowNameOverridesTheWorkspaceName() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new, windowName: "elsewhere").get()

        #expect(fixture.library.windowName(for: result.windowID) == "elsewhere")
        #expect(try readIndex().windows.last?.name == "elsewhere")
    }

    @Test func aWorkspaceMovesToAnOpenWindowAndKeepsItsActiveSession() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let active = project.sessions[1]
        fixture.store.selectSession(active.id)
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))
        let before = destinationStore.workspaces.map(\.id)

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .window(destination)).get()

        #expect(result.windowID == destination)
        #expect(!result.needsOpen)
        #expect(destinationStore.workspaces.map(\.id) == before + [project.id])
        #expect(destinationStore.selectedSessionID == active.id)
        #expect(try windowFile(destination).workspaces.map(\.id) == before + [project.id])
        #expect(fixture.store.session(withID: active.id) == nil)
    }

    @Test func aWorkspaceMovesToAClosedWindowWhichLoadsAndNeedsOpening() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let destination = fixture.library.newWindow(name: "dest").id
        fixture.library.closeWindow(destination)

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .window(destination)).get()

        #expect(result.needsOpen)
        #expect(fixture.library.isOpen(destination))
        #expect(fixture.library.store(for: destination)?.workspaces.last?.id == project.id)
        #expect(try windowFile(destination).workspaces.last?.id == project.id)
    }

    @Test func movedSessionsKeepTheirIdsAndPaneIdentities() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let split = project.sessions[0]
        split.hasSplit = true
        split.splitPaneIdentity = UUID()
        let identities = project.sessions.map { [$0.id, $0.paneIdentity, $0.splitPaneIdentity] as [UUID?] }

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new).get()

        let moved = try #require(fixture.library.store(for: result.windowID)?.workspaces.first?.sessions)
        #expect(moved.map { [$0.id, $0.paneIdentity, $0.splitPaneIdentity] as [UUID?] } == identities)
        let persisted = try #require(windowFile(result.windowID).workspaces.first?.sessions)
        #expect(persisted.map { [$0.id, $0.paneIdentity, $0.splitPaneIdentity] as [UUID?] } == identities)
    }

    @Test func theResultAnswersTheDestinationIdAndTheMovedCount() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new).get()

        #expect(result.sessionIDs == project.sessions.map(\.id))
        #expect(result.controlResult.id == result.windowID.uuidString)
        #expect(result.controlResult.affected == 2)
    }

    // MARK: - frontmost

    @Test(arguments: MoveDestination.allCases)
    func aWorkspaceMoveMakesTheDestinationFrontmost(_ kind: MoveDestination) throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let destination = destination(kind, fixture)

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: destination).get()

        #expect(fixture.library.frontmostWindowID == result.windowID)
        #expect(try readIndex().frontmost == result.windowID)
    }

    @Test(arguments: MoveDestination.allCases)
    func aSessionMoveMakesTheDestinationFrontmost(_ kind: MoveDestination) throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = destination(kind, fixture)

        let result = try fixture.library.transferSessions([moving.id], from: fixture.source, to: destination,
                                                          workspace: .none).get()

        #expect(fixture.library.frontmostWindowID == result.windowID)
        #expect(try readIndex().frontmost == result.windowID)
    }

    // MARK: - session moves

    @Test func anIdTargetLandsInThatWorkspaceOfAnOpenWindow() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))
        let target = destinationStore.addWorkspace(name: "landing")
        let before = destinationStore.workspaces.map(\.id)

        let result = try fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination),
                                                          workspace: .id(String(target.id.uuidString.prefix(8)))).get()

        #expect(result.sessionIDs == [moving.id])
        #expect(destinationStore.workspaces.map(\.id) == before)
        #expect(destinationStore.workspaces.last?.sessions.map(\.id) == [moving.id])
        #expect(destinationStore.selectedSessionID == moving.id)
        #expect(fixture.store.session(withID: moving.id) == nil)
    }

    @Test func anIdTargetIntoANewWindowIsRefused() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]

        try expectRefusal("a new window has no workspace ids; use --workspace-name", fixture) {
            fixture.library.transferSessions([moving.id], from: fixture.source, to: .new, workspace: .id("anything"))
        }
    }

    @Test func anUnknownIdTargetIsRefused() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id

        try expectRefusal("no such workspace: zzz", fixture) {
            fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination), workspace: .id("zzz"))
        }
    }

    @Test func aNameTargetReusesAnExistingWorkspace() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))
        let shared = destinationStore.addWorkspace(name: "shared")
        let before = destinationStore.workspaces.map(\.id)

        _ = try fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination),
                                                 workspace: .name("shared")).get()

        #expect(destinationStore.workspaces.map(\.id) == before)
        #expect(destinationStore.workspaces.first { $0.id == shared.id }?.sessions.map(\.id) == [moving.id])
    }

    @Test func aNameTargetCreatesAMissingWorkspace() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))
        let before = destinationStore.workspaces.map(\.id)

        _ = try fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination),
                                                 workspace: .name("fresh")).get()

        #expect(destinationStore.workspaces.count == before.count + 1)
        #expect(destinationStore.workspaces.last?.name == "fresh")
        #expect(destinationStore.workspaces.last?.sessions.map(\.id) == [moving.id])
    }

    @Test func aNameTargetIsTrimmedBeforeTheLookup() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))
        let shared = destinationStore.addWorkspace(name: "shared")
        let before = destinationStore.workspaces.map(\.id)

        _ = try fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination),
                                                 workspace: .name("  shared ")).get()

        #expect(destinationStore.workspaces.map(\.id) == before)
        #expect(destinationStore.workspaces.first { $0.id == shared.id }?.sessions.map(\.id) == [moving.id])
    }

    @Test func aBlankNameTargetIsRefused() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))
        let before = destinationStore.workspaces.map(\.id)

        for blank in ["", "   ", "\u{07}"] {
            let result = fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination),
                                                          workspace: .name(blank))
            #expect(throws: TransferRefusal.self) { try result.get() }
            let newResult = fixture.library.transferSessions([moving.id], from: fixture.source, to: .new,
                                                             workspace: .name(blank))
            #expect(throws: TransferRefusal.self) { try newResult.get() }
        }
        #expect(destinationStore.workspaces.map(\.id) == before)
        #expect(try fixture.workspace("project").sessions.contains { $0.id == moving.id })
    }

    @Test func noTargetUsesTheFirstMovedSessionsWorkspaceName() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[1]

        let result = try fixture.library.transferSessions([moving.id], from: fixture.source, to: .new, workspace: .none).get()

        let store = try #require(fixture.library.store(for: result.windowID))
        #expect(store.workspaces.map(\.name) == ["project"])
        #expect(store.workspaces[0].sessions.map(\.id) == [moving.id])
        #expect(fixture.library.windowName(for: result.windowID) == "project")
        #expect(fixture.store.workspaces.contains { $0.name == "project" })
    }

    @Test func aBatchFromTwoWorkspacesLandsInOneWorkspaceInTreeOrder() throws {
        let fixture = try makeFixture()
        let api = try fixture.workspace("project").sessions[0]
        let other = fixture.store.addWorkspace(name: "other")
        let db = try #require(fixture.store.addSession(toWorkspace: other.id, cwd: "/db", name: "db"))
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))

        let result = try fixture.library.transferSessions([db.id, api.id], from: fixture.source, to: .window(destination),
                                                          workspace: .none).get()

        #expect(result.sessionIDs == [api.id, db.id])
        #expect(destinationStore.workspaces.last?.name == "project")
        #expect(destinationStore.workspaces.last?.sessions.map(\.id) == [api.id, db.id])
        #expect(try fixture.workspace("other").sessions.isEmpty)
    }

    @Test func aSingleSessionMovesToANewWindowNamedAfterItsTarget() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[1]

        let result = try fixture.library.transferSessions([moving.id], from: fixture.source, to: .new, workspace: .name("solo")).get()

        let store = try #require(fixture.library.store(for: result.windowID))
        #expect(store.workspaces.map(\.name) == ["solo"])
        #expect(store.workspaces[0].sessions.map(\.id) == [moving.id])
        #expect(fixture.library.windowName(for: result.windowID) == "solo")
        #expect(result.controlResult.affected == 1)
        #expect(try fixture.workspace("project").sessions.count == 1)
    }

    // MARK: - ordering

    @Test func aFailedDestinationSaveLeavesTheSourceLive() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let surfaces = project.sessions.map { session in
            let surface = MoveSpySurface(backedByZmx: true)
            session.surface = surface
            return surface
        }
        let destination = fixture.library.newWindow(name: "dest").id
        fixture.library.frontmostWindowID = fixture.source
        let destinationStore = try #require(fixture.library.store(for: destination))
        let selection = destinationStore.selectedSessionID
        let workspaces = destinationStore.workspaces.map(\.id)
        let files = fileState()
        try makeWindowsReadOnly()

        let result = fixture.library.transferWorkspace(project.id, from: fixture.source, to: .window(destination))
        try restoreWindowsDirectory()

        #expect(result == .failure(TransferRefusal("destination save failed")))
        #expect(fixture.library.frontmostWindowID == fixture.source)
        #expect(try fixture.workspace("project").sessions.map(\.id) == project.sessions.map(\.id))
        #expect(zip(project.sessions, surfaces).allSatisfy { $0.surface === $1 })
        #expect(surfaces.allSatisfy { $0.prepareCount == 0 && $0.teardownCount == 0 })
        #expect(destinationStore.workspaces.map(\.id) == workspaces)
        #expect(destinationStore.selectedSessionID == selection)
        #expect(fileState() == files)
    }

    @Test func aFailedSaveDropsANewWindow() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let windows = fixture.library.windows
        let frontmost = fixture.library.frontmostWindowID
        let files = fileState()
        try makeWindowsReadOnly()

        let result = fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new)
        try restoreWindowsDirectory()

        #expect(result == .failure(TransferRefusal("destination save failed")))
        #expect(fixture.library.windows == windows)
        #expect(fixture.library.frontmostWindowID == frontmost)
        #expect(fixture.library.openIDs() == windows.map(\.id))
        #expect(fileState() == files)
        #expect(fixture.store.workspaces.contains { $0.id == project.id })
    }

    @Test func aFailedSaveClosesAClosedDestinationAgain() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let destination = fixture.library.newWindow(name: "dest").id
        fixture.library.closeWindow(destination)
        fixture.library.frontmostWindowID = fixture.source
        let files = fileState()
        try makeWindowsReadOnly()

        let result = fixture.library.transferWorkspace(project.id, from: fixture.source, to: .window(destination))
        try restoreWindowsDirectory()

        #expect(result == .failure(TransferRefusal("destination save failed")))
        #expect(!fixture.library.isOpen(destination))
        #expect(fixture.library.frontmostWindowID == fixture.source)
        #expect(fileState() == files)
        #expect(fixture.store.workspaces.contains { $0.id == project.id })
    }

    @Test func aFailedSaveWithdrawsACreatedWorkspace() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        let destinationStore = try #require(fixture.library.store(for: destination))
        let workspaces = destinationStore.workspaces.map(\.id)
        let selection = destinationStore.selectedSessionID
        try makeWindowsReadOnly()

        let result = fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination),
                                                      workspace: .name("fresh"))
        try restoreWindowsDirectory()

        #expect(result == .failure(TransferRefusal("destination save failed")))
        #expect(destinationStore.workspaces.map(\.id) == workspaces)
        #expect(destinationStore.selectedSessionID == selection)
        #expect(fixture.store.session(withID: moving.id) === moving)
    }

    // MARK: - claims

    @Test func aRelaunchClaimsEveryMovedPane() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        project.sessions[0].hasSplit = true
        project.sessions[0].splitPaneIdentity = UUID()
        fixture.store.save()
        let moved = Set(project.sessions.flatMap { [$0.paneIdentity, $0.splitPaneIdentity].compactMap(\.self) })
        #expect(moved.count == 3)

        _ = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new).get()
        var inventories: [Set<UUID>?] = []
        _ = WindowLibrary(directory: directory, paneFinalizer: nil, launchInventorySink: { inventories.append($0) })

        #expect(inventories.count == 1)
        let claimed = try #require(inventories.first ?? nil)
        #expect(moved.isSubset(of: claimed))
    }

    @Test func aMovedRemoteRowIsRecordedInTheDestinationWindow() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let row = try #require(fixture.store.addSession(toWorkspace: project.id, cwd: "/tmp", remoteHost: "buildbox"))
        fixture.store.bindRemote(RemoteBinding(remoteSessionID: "remote-id",
            daemonsByLocalPane: [row.paneIdentity: ZmxSupport.daemonName(for: UUID())], presentationVersion: 1,
            origin: RemoteBinding.Origin(host: "buildbox",
                endpoint: ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/remote-zmx"),
                sessionName: "remote-session", transport: .ssh)), forSession: row.id)
        let destination = fixture.library.newWindow(name: "dest").id

        _ = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .window(destination)).get()

        let records = RemoteRowBook.records(from: fixture.library, previous: [])
        #expect(records.count == 1)
        #expect(records.first?.windowID == destination)
        #expect(records.first?.workspaceID == project.id)
    }

    // MARK: - last workspace

    @Test(arguments: [MoveDestination.new, .open])
    func theOnlyWorkspaceMovesAndItsWindowIsDeleted(_ kind: MoveDestination) throws {
        let (fixture, only) = try makeLoneFixture()
        fixture.store.save()
        #expect(FileManager.default.fileExists(atPath: windowFileURL(fixture.source).path))
        let destination = destination(kind, fixture)

        let result = try fixture.library.transferWorkspace(only.id, from: fixture.source, to: destination).get()

        #expect(result.removedSourceWindow == fixture.source)
        #expect(fixture.library.store(for: result.windowID)?.workspaces.last?.id == only.id)
        #expect(!fixture.library.windows.contains { $0.id == fixture.source })
        #expect(fixture.library.stores[fixture.source] == nil)
        #expect(!FileManager.default.fileExists(atPath: windowFileURL(fixture.source).path))
        let index = try readIndex()
        #expect(index.frontmost == result.windowID)
        #expect(!index.windows.contains { $0.id == fixture.source })
    }

    @Test func theWindowDeleteFinalizesClosesAndReleasesNoMovedSession() throws {
        let (fixture, only) = try makeLoneFixture()
        only.sessions[0].hasSplit = true
        only.sessions[0].splitPaneIdentity = UUID()
        let moved = Set(only.sessions.flatMap { [$0.paneIdentity, $0.splitPaneIdentity].compactMap(\.self) })
        let movedIDs = Set(only.sessions.map(\.id.uuidString))
        events.removeAll()

        _ = try fixture.library.transferWorkspace(only.id, from: fixture.source, to: .new).get()

        #expect(fixture.store.workspaces.isEmpty)
        #expect(moved.isDisjoint(with: finalized))
        #expect(!events.contains { $0.kind == .sessionClosed && movedIDs.contains($0.session ?? "") })
    }

    @Test func aRelaunchClaimsEveryPaneOfAMovedLastWorkspace() throws {
        let (fixture, only) = try makeLoneFixture()
        only.sessions[0].hasSplit = true
        only.sessions[0].splitPaneIdentity = UUID()
        fixture.store.save()
        let moved = Set(only.sessions.flatMap { [$0.paneIdentity, $0.splitPaneIdentity].compactMap(\.self) })

        _ = try fixture.library.transferWorkspace(only.id, from: fixture.source, to: .new).get()
        var inventories: [Set<UUID>?] = []
        _ = WindowLibrary(directory: directory, paneFinalizer: nil, launchInventorySink: { inventories.append($0) })

        let claimed = try #require(inventories.first ?? nil)
        #expect(moved.isSubset(of: claimed))
    }

    @Test func aFailedSaveOnALastWorkspaceMoveKeepsTheSourceWindow() throws {
        let (fixture, only) = try makeLoneFixture()
        fixture.store.save()
        let windows = fixture.library.windows
        let files = fileState()
        try makeWindowsReadOnly()

        let result = fixture.library.transferWorkspace(only.id, from: fixture.source, to: .new)
        try restoreWindowsDirectory()

        #expect(result == .failure(TransferRefusal("destination save failed")))
        #expect(fixture.library.windows == windows)
        #expect(fixture.library.stores[fixture.source] === fixture.store)
        #expect(fixture.store.workspaces.map(\.id) == [only.id])
        #expect(fileState() == files)
    }

    @Test func aPendingCloseInsideTheOnlyWorkspaceIsStillRefused() throws {
        let (fixture, only) = try makeLoneFixture()
        #expect(fixture.store.softCloseSession(only.sessions[0].id, grace: 3600))

        try expectRefusal("workspace has a pending close", fixture) {
            fixture.library.transferWorkspace(only.id, from: fixture.source, to: .new)
        }
    }

    @Test func theWindowDeleteFinalizesAnotherPendingWorkspaceClose() throws {
        let (fixture, closing) = try makeLoneFixture()
        let project = fixture.store.addWorkspace(name: "project")
        _ = fixture.store.addSession(toWorkspace: project.id, cwd: "/api", name: "api")
        let doomed = Set(closing.sessions.map(\.paneIdentity))
        #expect(fixture.store.softRemoveWorkspace(closing.id, grace: 3600))
        #expect(finalized.isEmpty)

        let result = try fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new).get()

        #expect(result.removedSourceWindow == fixture.source)
        #expect(doomed.isSubset(of: finalized))
    }

    @Test func aSessionMoveThatEmptiesTheOnlyWorkspaceKeepsTheSourceWindow() throws {
        let (fixture, only) = try makeLoneFixture()

        let result = try fixture.library.transferSessions(only.sessions.map(\.id), from: fixture.source, to: .new,
                                                          workspace: .none).get()

        #expect(result.removedSourceWindow == nil)
        #expect(fixture.library.stores[fixture.source] === fixture.store)
        #expect(fixture.library.windows.contains { $0.id == fixture.source })
        #expect(fixture.store.workspaces.map(\.id) == [only.id])
        #expect(fixture.store.workspaces[0].sessions.isEmpty)
    }

    // MARK: - refusals

    @Test func aWorkspaceWithAPendingCloseIsRefused() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        #expect(fixture.store.softCloseSession(project.sessions[0].id, grace: 3600))

        try expectRefusal("workspace has a pending close", fixture) {
            fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new)
        }
    }

    @Test func aPaneThatCannotSurviveIsRefused() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let plain = project.sessions[1]
        plain.surface = MoveSpySurface(backedByZmx: false)

        try expectRefusal("pane not zmx-backed: \(plain.id.uuidString)", fixture) {
            fixture.library.transferWorkspace(project.id, from: fixture.source, to: .new)
        }
        try expectRefusal("pane not zmx-backed: \(plain.id.uuidString)", fixture) {
            fixture.library.transferSessions([plain.id], from: fixture.source, to: .new, workspace: .none)
        }
    }

    @Test func theSourceWindowIsRefusedAsADestination() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")

        try expectRefusal("same window", fixture) {
            fixture.library.transferWorkspace(project.id, from: fixture.source, to: .window(fixture.source))
        }
    }

    @Test func anUnknownDestinationIsRefused() throws {
        let fixture = try makeFixture()
        let project = try fixture.workspace("project")
        let unknown = UUID()

        try expectRefusal("no such window: \(unknown.uuidString)", fixture) {
            fixture.library.transferWorkspace(project.id, from: fixture.source, to: .window(unknown))
        }
    }

    @Test func anUnresolvedDestinationChangesNothing() throws {
        let fixture = try makeFixture()
        let files = fileState()
        let shape = shape(fixture.library)

        #expect(throws: TransferRefusal("no such window: nowhere")) {
            try fixture.library.resolveTransferDestination("nowhere", source: fixture.source).get()
        }
        #expect(fileState() == files)
        #expect(self.shape(fixture.library) == shape)
    }

    @Test func aRefusedIdIntoAClosedWindowLeavesItClosed() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        fixture.library.closeWindow(destination)

        try expectRefusal("no such workspace: zzz", fixture) {
            fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination), workspace: .id("zzz"))
        }
        #expect(!fixture.library.isOpen(destination))
    }

    @Test func anIdTargetResolvesAgainstAClosedWindowsFile() throws {
        let fixture = try makeFixture()
        let moving = try fixture.workspace("project").sessions[0]
        let destination = fixture.library.newWindow(name: "dest").id
        let target = try #require(fixture.library.store(for: destination)?.addWorkspace(name: "landing"))
        fixture.library.closeWindow(destination)

        let result = try fixture.library.transferSessions([moving.id], from: fixture.source, to: .window(destination),
                                                          workspace: .id(target.id.uuidString)).get()

        #expect(result.needsOpen)
        #expect(fixture.library.store(for: destination)?.workspaces.last?.sessions.map(\.id) == [moving.id])
    }

    // MARK: - fixtures

    @MainActor
    private struct Fixture {
        let library: WindowLibrary
        let source: UUID
        let store: AppStore

        func workspace(_ name: String) throws -> Workspace {
            try #require(store.workspaces.first { $0.name == name })
        }
    }

    private func makeFixture() throws -> Fixture {
        let library = WindowLibrary(directory: directory)
        let source = try #require(library.activeWindowID)
        let store = try #require(library.activeStore)
        let project = store.addWorkspace(name: "project")
        _ = store.addSession(toWorkspace: project.id, cwd: "/api", name: "api")
        _ = store.addSession(toWorkspace: project.id, cwd: "/web", name: "web")
        return Fixture(library: library, source: source, store: store)
    }

    /// The launch window's only workspace with a second session, recording finalized panes and events.
    private func makeLoneFixture() throws -> (Fixture, Workspace) {
        let library = WindowLibrary(directory: directory, paneFinalizer: { [weak self] in self?.finalized += $0 })
        library.onControlEvent = { [weak self] in self?.events.append($0) }
        let store = try #require(library.activeStore)
        let only = try #require(store.workspaces.first)
        _ = store.addSession(toWorkspace: only.id, cwd: "/web", name: "web")
        let fixture = Fixture(library: library, source: try #require(library.activeWindowID), store: store)
        return (fixture, try #require(store.workspaces.first))
    }

    /// `open` and `closed` leave the source frontmost, as it is when a move starts from it.
    private func destination(_ kind: MoveDestination, _ fixture: Fixture) -> TransferDestination {
        guard kind != .new else { return .new }
        let id = fixture.library.newWindow(name: "dest").id
        if kind == .closed { fixture.library.closeWindow(id) }
        fixture.library.frontmostWindowID = fixture.source
        return .window(id)
    }

    private func expectRefusal(_ message: String, _ fixture: Fixture,
                               _ move: () -> Result<TransferResult, TransferRefusal>,
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
        let files = fileState()
        let shape = shape(fixture.library)
        #expect(move() == .failure(TransferRefusal(message)), sourceLocation: sourceLocation)
        #expect(fileState() == files, sourceLocation: sourceLocation)
        #expect(self.shape(fixture.library) == shape, sourceLocation: sourceLocation)
    }

    private func shape(_ library: WindowLibrary) -> [String] {
        library.windows.map { window in
            let tree = library.stores[window.id].map { store in
                store.workspaces.map { "\($0.id):\($0.sessions.map(\.id))" }.joined(separator: ",")
            } ?? "closed"
            return "\(window.id) \(window.name) \(tree)"
        }
    }

    private func fileState() -> [String: Data] {
        var state: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            state[url.lastPathComponent] = try? Data(contentsOf: url)
        }
        return state
    }

    private func makeWindowsReadOnly() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.appendingPathComponent("windows").path)
    }

    private func restoreWindowsDirectory() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("windows").path)
    }

    private func readIndex() throws -> WindowsIndex {
        try JSONDecoder().decode(WindowsIndex.self, from: Data(contentsOf: directory.appendingPathComponent("windows.json")))
    }

    private func windowFileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("windows").appendingPathComponent("\(id.uuidString).json")
    }

    private func windowFile(_ id: UUID) throws -> Snapshot {
        try PersistenceStore(directory: directory.appendingPathComponent("windows"), fileName: "\(id.uuidString).json").loadChecked()
    }
}

enum MoveDestination: CaseIterable, Sendable {
    case new, open, closed
}

private final class MoveSpySurface: TerminalSurface {
    let paneToken = ""
    let isRealized = true
    let backedByZmx: Bool
    var teardownCount = 0
    var prepareCount = 0
    init(backedByZmx: Bool) { self.backedByZmx = backedByZmx }
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() {}
    func prepareForTransfer() { prepareCount += 1 }
}
