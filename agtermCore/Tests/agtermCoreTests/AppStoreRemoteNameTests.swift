import Foundation
import Testing
@testable import agtermCore

/// A remote row's name belongs to its origin: the origin publishes its custom name, a rename on the viewer
/// travels to the origin and stays pending until the origin echoes it.
@MainActor
struct AppStoreRemoteNameTests {
    private final class RecordingSink: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}

        var names: [String?] {
            frames.compactMap { if case .name(let name) = $0.body { return .some(name) } else { return nil } }
        }
    }

    // MARK: - origin

    private func origin(name: String? = nil) throws -> (AppStore, Session, RecordingSink) {
        let store = makeStore()
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo", name: name))
        let sink = RecordingSink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: ["name"], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }
        return (store, session, sink)
    }

    @Test func aRenameReachesTheHubAndAClearTravelsAsNone() throws {
        let (store, session, sink) = try origin()

        #expect(store.renameSession(session.id, to: "deploy box"))
        #expect(store.renameSession(session.id, to: "  "))

        #expect(sink.names == ["deploy box", nil])
    }

    @Test func anUnchangedRenamePublishesNothingAndSaysSo() throws {
        let (store, session, sink) = try origin(name: "deploy box")

        #expect(!store.renameSession(session.id, to: "deploy box"))

        #expect(sink.names.isEmpty)
    }

    @Test func theSnapshotCarriesTheCustomNameOnly() throws {
        let (store, session, _) = try origin()
        #expect(store.presentationSnapshot(forSession: session.id).name == nil)

        store.renameSession(session.id, to: "deploy box")

        #expect(store.presentationSnapshot(forSession: session.id).name == "deploy box")
    }

    @Test func aViewersRenameIsPublishedOnceAndOneThatChangesNothingIsEchoed() throws {
        let (store, session, sink) = try origin()

        #expect(store.renameFromViewer(session.id, to: "deploy box"))
        #expect(!store.renameFromViewer(session.id, to: " deploy box "))
        #expect(store.renameFromViewer(session.id, to: nil))
        #expect(!store.renameFromViewer(session.id, to: "   "))

        #expect(sink.names == ["deploy box", "deploy box", nil, nil])
        #expect(session.customName == nil)
    }

    @Test(arguments: [" deploy box ", "tab\tand\u{7}bell", "line\nbreak", "\u{1b}[31mred", "   "])
    func sanitizingAnAlreadySanitizedNameChangesNothing(_ raw: String) {
        let once = TerminalText.sanitized(raw).trimmedOrNil
        #expect(once.flatMap { TerminalText.sanitized($0).trimmedOrNil } == once)
    }

    @Test func renamingAnOriginSessionCallsNoViewerHook() throws {
        let (store, session, _) = try origin()
        store.onRemoteSessionRenamed = { _, _ in Issue.record("a local session has no origin to tell") }

        store.renameSession(session.id, to: "deploy box")
    }

    // MARK: - viewer

    private func attached(name: String? = "sasha", store: AppStore? = nil) throws -> (AppStore, Session) {
        let store = store ?? makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", name: name, remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1",
                                       daemonsByLocalPane: [session.paneIdentity: "s1-left"],
                                       presentationVersion: 1), forSession: session.id)
        return (store, session)
    }

    @Test func renamingARemoteRowShowsTheNameAndAsksTheOrigin() throws {
        let (store, session) = try attached()
        var asked: [(UUID, String?)] = []
        store.onRemoteSessionRenamed = { asked.append(($0, $1)) }

        store.renameSession(session.id, to: " deploy box ")
        store.renameSession(session.id, to: "")

        #expect(asked.map(\.0) == [session.id, session.id])
        #expect(asked.map(\.1) == ["deploy box", nil])
        #expect(session.customName == nil)
        #expect(session.remotePresentation?.namePending == true)
    }

    @Test func theOriginsEchoEndsThePendingRename() throws {
        let (store, session) = try attached()
        store.renameSession(session.id, to: "deploy box")

        store.applyRemoteName("deploy box", forSession: session.id)

        #expect(session.customName == "deploy box")
        #expect(session.remotePresentation?.namePending == false)
    }

    @Test func anotherNameWhilePendingIsIgnoredUntilTheEcho() throws {
        let (store, session) = try attached()
        store.renameSession(session.id, to: "mine")

        store.applyRemoteName("theirs", forSession: session.id)
        #expect(session.customName == "mine")
        #expect(session.remotePresentation?.namePending == true)

        store.applyRemoteName("mine", forSession: session.id)
        store.applyRemoteName("theirs", forSession: session.id)
        #expect(session.customName == "theirs")
        #expect(session.remotePresentation?.namePending == false)
    }

    @Test func aClearedRenameIsEchoedAsNone() throws {
        let (store, session) = try attached()
        store.renameSession(session.id, to: "")

        store.applyRemoteName(nil, forSession: session.id)

        #expect(session.customName == nil)
        #expect(session.remotePresentation?.namePending == false)
    }

    @Test func theOriginsNameReplacesTheRowsAndIsSanitized() throws {
        let (store, session) = try attached()

        store.applyRemoteName(" deploy\u{1b}box ", forSession: session.id)
        #expect(session.customName == TerminalText.sanitized(" deploy\u{1b}box ").trimmedOrNil)

        store.applyRemoteName("   ", forSession: session.id)
        #expect(session.customName == nil)
    }

    @Test func aSnapshotNameIsAppliedWhenNothingIsPending() throws {
        let (store, session) = try attached()

        #expect(!store.applyRemoteSnapshotName("deploy box", forSession: session.id))

        #expect(session.customName == "deploy box")
    }

    @Test func aSnapshotWhileARenameIsPendingKeepsItAndAsksForItToBeSent() throws {
        let (store, session) = try attached()
        store.renameSession(session.id, to: "mine")

        #expect(store.applyRemoteSnapshotName("sasha", forSession: session.id))
        #expect(session.customName == "mine")
        #expect(session.remotePresentation?.namePending == true)

        store.renameSession(session.id, to: "")
        #expect(store.applyRemoteSnapshotName("sasha", forSession: session.id))
        #expect(session.customName == nil)
    }

    @Test func aSnapshotThatAlreadyCarriesThePendingNameEndsIt() throws {
        let (store, session) = try attached()
        store.renameSession(session.id, to: "mine")

        #expect(!store.applyRemoteSnapshotName(" mine ", forSession: session.id))

        #expect(session.customName == "mine")
        #expect(session.remotePresentation?.namePending == false)
    }

    @Test func anEarlierEchoOfTheSameNameDoesNotEndALaterRename() throws {
        let (store, session) = try attached()
        store.renameSession(session.id, to: "x")
        store.renameSession(session.id, to: "y")
        store.renameSession(session.id, to: "x")

        store.applyRemoteName("x", forSession: session.id)
        store.applyRemoteName("y", forSession: session.id)
        #expect(session.customName == "x")
        #expect(session.remotePresentation?.namePending == true)

        // the stream drops before the last rename reaches the origin; the next snapshot sends it again
        #expect(store.applyRemoteSnapshotName("y", forSession: session.id))
        store.applyRemoteName("x", forSession: session.id)

        #expect(session.customName == "x")
        #expect(session.remotePresentation?.namePending == false)
    }

    @Test func aSnapshotCarryingThePendingNameEndsItWhateverWasInFlight() throws {
        let (store, session) = try attached()
        store.renameSession(session.id, to: "x")
        store.renameSession(session.id, to: "y")

        #expect(!store.applyRemoteSnapshotName("y", forSession: session.id))
        #expect(session.remotePresentation?.namePending == false)

        store.applyRemoteName("z", forSession: session.id)
        #expect(session.customName == "z")
    }

    @Test func aPendingRenameRestoredFromTheBookEndsOnItsEcho() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", name: "mine", remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [session.paneIdentity: "s1-left"],
                                       presentationVersion: 1), forSession: session.id, namePending: true)

        store.applyRemoteName("theirs", forSession: session.id)
        #expect(session.remotePresentation?.namePending == true)
        store.applyRemoteName("mine", forSession: session.id)

        #expect(session.customName == "mine")
        #expect(session.remotePresentation?.namePending == false)
    }

    @Test func aNameOverTheByteLimitIsRefusedAndNotSent() throws {
        let (store, session) = try attached(name: "kept")
        store.onRemoteSessionRenamed = { _, _ in Issue.record("a refused name must not reach the origin") }

        #expect(!store.renameSession(session.id, to: String(repeating: "é", count: Session.nameByteLimit / 2 + 1)))
        #expect(session.customName == "kept")
        #expect(session.remotePresentation?.namePending == false)

        store.onRemoteSessionRenamed = nil
        #expect(store.renameSession(session.id, to: String(repeating: "a", count: Session.nameByteLimit)))
    }

    @Test func aNewSessionDropsANameOverTheByteLimit() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let long = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo",
                                                 name: String(repeating: "a", count: Session.nameByteLimit + 1)))
        let fits = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo",
                                                 name: String(repeating: "a", count: Session.nameByteLimit)))

        #expect(long.customName == nil)
        #expect(fits.customName?.utf8.count == Session.nameByteLimit)
    }

    @Test func aRestoredNameOverTheByteLimitIsDroppedSoTheSnapshotStillEncodes() throws {
        let store = makeStore()
        let saved = SessionSnapshot(id: UUID(), customName: String(repeating: "a", count: 300_000), cwd: "/repo")
        let fits = SessionSnapshot(id: UUID(), customName: "deploy box", cwd: "/repo")

        let restored = store.session(from: saved)
        #expect(restored.customName == nil)
        #expect(store.session(from: fits).customName == "deploy box")

        let ws = store.addWorkspace(name: "work")
        let index = try #require(store.workspaces.firstIndex { $0.id == ws.id })
        store.workspaces[index].sessions.append(restored)
        let frame = PresentationFrame(gen: 1, rev: 1, body: .snapshot(store.presentationSnapshot(forSession: restored.id)))
        #expect(throws: Never.self) { try PresentationCodec.encode(frame) }
    }

    @Test func theOriginEchoesItsOwnNameForARenameOverTheLimit() throws {
        let (store, session, sink) = try origin(name: "kept")

        #expect(!store.renameFromViewer(session.id, to: String(repeating: "a", count: Session.nameByteLimit + 1)))

        #expect(session.customName == "kept")
        #expect(sink.names == ["kept"])
    }

    @Test func theOriginsNameIsNeverSentBack() throws {
        let (store, session) = try attached()
        store.onRemoteSessionRenamed = { _, _ in Issue.record("an applied name is the origin's own") }

        store.applyRemoteName("deploy box", forSession: session.id)
        #expect(!store.applyRemoteSnapshotName("other", forSession: session.id))

        #expect(session.customName == "other")
    }

    @Test func losingTheStreamKeepsTheName() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        store.applyRemoteName("deploy box", forSession: session.id)

        store.setRemoteConnection(.failed("offline"), forSession: session.id)

        #expect(session.customName == "deploy box")
    }

    @Test func aNameIsIgnoredOnALocalSession() throws {
        let (store, session, _) = try origin(name: "local")

        store.applyRemoteName("theirs", forSession: session.id)
        #expect(!store.applyRemoteSnapshotName("theirs", forSession: session.id))

        #expect(session.customName == "local")
    }

    @Test func thePendingRenameReadsBackInTheTree() throws {
        let (store, session) = try attached()
        #expect(store.controlTree().workspaces[0].sessions[0].presentation?.namePending == nil)

        store.renameSession(session.id, to: "deploy box")
        #expect(store.controlTree().workspaces[0].sessions[0].presentation?.namePending == true)

        store.applyRemoteName("deploy box", forSession: session.id)
        #expect(store.controlTree().workspaces[0].sessions[0].presentation?.namePending == nil)
    }

    @Test func nameChangesAnnounceTheTreeAndAnEchoOfTheSameNameDoesToo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var events: [ControlEventKind] = []
        let store = AppStore(persistence: PersistenceStore(directory: directory),
                             controlEventSink: { events.append($0.kind) }, paneFinalizer: nil)
        let (_, session) = try attached(store: store)
        events.removeAll()

        store.applyRemoteName("deploy box", forSession: session.id)
        #expect(events == [.treeChanged])
        events.removeAll()
        store.applyRemoteName("deploy box", forSession: session.id)
        #expect(events.isEmpty)

        store.renameSession(session.id, to: "mine")
        #expect(events == [.treeChanged])
        events.removeAll()
        // the echo changes no name, only the pending flag the row book and the tree carry
        store.applyRemoteName("mine", forSession: session.id)
        #expect(events == [.treeChanged])
    }
}
