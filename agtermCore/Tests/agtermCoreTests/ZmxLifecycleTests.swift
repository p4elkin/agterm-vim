import Foundation
import Testing
@testable import agtermCore

/// Records what a store asked zmx to do, so a test asserts on the effects rather than on the predicate twice.
@MainActor
final class ZmxSinkSpy {
    private(set) var ended: [String] = []
    private(set) var labelled: [(key: String, name: String)] = []

    var sink: ZmxSessionSink {
        ZmxSessionSink(end: { [weak self] in self?.ended.append($0) },
                       label: { [weak self] key, name in self?.labelled.append((key, name)) })
    }
}

@MainActor
struct ZmxLifecycleTests {
    private let id = UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427")!
    private var left: String { "\(id.uuidString)-left" }
    private var right: String { "\(id.uuidString)-right" }

    private func row(primary: String? = nil, split: String? = nil) -> ZmxLifecycle.Row {
        ZmxLifecycle.Row(primaryKey: primary, splitKey: split)
    }

    /// One surface build, as `agtermApp`'s factories perform it: decide from the keys the row already holds,
    /// then record what was wrapped. Returns the key the pane took, nil when it was left a plain shell.
    @discardableResult
    private func buildPane(_ store: AppStore, _ session: Session, role: ZmxSessionKey.Role) -> String? {
        let keys = session.zmxKeys(for: role)
        let inputs = ZmxWrap.Inputs(sessionID: session.id, role: role, existingKey: keys.own,
                                    siblingKey: keys.sibling, pinnedCommand: nil, keepShellOpen: false,
                                    shell: "/bin/zsh", zmxPath: "/opt/homebrew/bin/zmx", budgetReason: nil,
                                    isolatedStateDir: false)
        guard case let .wrap(_, key) = ZmxWrap.decide(inputs) else { return nil }
        store.recordZmxSession(key, role: role, forSession: session)
        return key
    }

    /// A session whose panes were wrapped, as the surface factories leave it.
    @discardableResult
    private func wrapSession(_ session: Session, split: Bool = false) -> Session {
        session.zmxPrimaryKey = "\(session.id.uuidString)-left"
        if split { session.zmxSplitKey = "\(session.id.uuidString)-right" }
        return session
    }

    // MARK: - the predicate

    @Test func rowCloseEndsTheOnePaneKey() {
        #expect(ZmxLifecycle.keysToEnd(row(primary: left), close: .row) == [left])
    }

    @Test func rowCloseWithASplitEndsBothPaneKeys() {
        #expect(ZmxLifecycle.keysToEnd(row(primary: left, split: right), close: .row) == [left, right])
    }

    @Test func splitCloseEndsOnlyTheSplitKey() {
        #expect(ZmxLifecycle.keysToEnd(row(primary: left, split: right), close: .split) == [right])
        #expect(ZmxLifecycle.keysToEnd(row(primary: left), close: .split).isEmpty)
    }

    @Test func windowCloseEndsNothing() {
        #expect(ZmxLifecycle.keysToEnd(row(primary: left, split: right), close: .window).isEmpty)
    }

    /// ⚠️ The client that went away may have DETACHED, leaving a live agent in the session behind it.
    @Test func aClientExitEndsNothing() {
        #expect(ZmxLifecycle.keysToEnd(row(primary: left, split: right), close: .clientExit).isEmpty)
    }

    @Test func anUnwrappedRowOwnsNothing() {
        #expect(ZmxLifecycle.keysToEnd(row(), close: .row).isEmpty)
        #expect(ZmxLifecycle.ownedKeys(row()).isEmpty)
        // an unwrapped left pane beside a wrapped split still ends only the split's key
        #expect(ZmxLifecycle.keysToEnd(row(split: right), close: .row) == [right])
    }

    /// A promoted survivor's key is `-right` while the model calls it the main pane, so ownership can never
    /// be re-derived from the role.
    @Test func aPromotedRowOwnsTheKeyItActuallyAttachedTo() {
        #expect(ZmxLifecycle.keysToEnd(row(primary: right), close: .row) == [right])
    }

    // MARK: - the store

    @Test func closingARowEndsItsSessions() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!, split: true)
        store.toggleSplit(session.id)
        store.closeSession(session.id)
        #expect(spy.ended == ["\(session.id.uuidString)-left", "\(session.id.uuidString)-right"])
    }

    @Test func closingAnUnwrappedRowEndsNothing() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        store.closeSession(session.id)
        #expect(spy.ended.isEmpty)
    }

    @Test func closingTheSplitEndsOnlyTheSplitSession() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!, split: true)
        store.toggleSplit(session.id)
        store.closeSplit(session.id)
        #expect(spy.ended == ["\(session.id.uuidString)-right"])
        #expect(session.zmxSplitKey == nil, "the right pane is gone, so the row stops owning its key")
    }

    // MARK: - a pane's own exit

    /// ⚠️ The path that actually fires in production. Under wrapping the pane's process IS the zmx client, so
    /// its exit means only that the client went away: the user may have detached from a session still running
    /// their agent. `agtermApp.handlePaneExit` routes here, and it must end nothing.
    @Test func theSplitPanesOwnExitEndsNothing() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!, split: true)
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        store.toggleSplit(session.id)
        store.closeSplitPane(session.id)
        #expect(spy.ended.isEmpty)
        #expect(store.session(withID: session.id) != nil)
    }

    @Test func thePrimaryPanesOwnExitEndsNothing() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!)
        store.closePrimaryPane(session.id) // no split: the whole row goes, but its daemon may be detached
        #expect(spy.ended.isEmpty)
        #expect(store.session(withID: session.id) == nil)
    }

    /// ⚠️ The critical case: the survivor keeps attaching to `-right`, so the row must own THAT key
    /// afterwards. Re-deriving `-left` here kills the wrong daemon on close and lets a later ⌘D open a second
    /// client on the live one.
    @Test func aPromotedSurvivorCarriesItsOwnKeyIntoTheMainSlot() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!, split: true)
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        store.closePrimaryPane(session.id)
        #expect(session.zmxPrimaryKey == "\(session.id.uuidString)-right")
        #expect(session.zmxSplitKey == nil)
        #expect(spy.ended.isEmpty)
        store.closeSession(session.id)
        #expect(spy.ended == ["\(session.id.uuidString)-right"])
    }

    @Test func aPromotedRowIsRenamedUnderItsOwnKey() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!, split: true)
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        store.closePrimaryPane(session.id)
        store.renameSession(session.id, to: "rebase")
        #expect(spy.labelled.map(\.key) == ["\(session.id.uuidString)-right"])
    }

    // MARK: - what a surface build records

    /// ⚠️ Command-D after a promotion. The main pane is a live client of `-right`, so the split factory must
    /// not derive `-right` a second time: both panes would drive one terminal and an `exit` in either would
    /// end the agent in both. A restart replays the same decision off the snapshot, so it must hold there too.
    @Test func aReSplitAfterAPromotionNeverTakesTheMainPanesKey() {
        let store = makeStore(zmx: ZmxSinkSpy().sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        buildPane(store, session, role: .left)
        buildPane(store, session, role: .right)
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        store.closePrimaryPane(session.id)

        #expect(buildPane(store, session, role: .right) == nil)
        #expect(session.zmxPrimaryKey == "\(session.id.uuidString)-right")
        #expect(session.zmxSplitKey == nil)

        let restored = store.session(from: store.sessionSnapshot(session))
        #expect(buildPane(store, restored, role: .left) == "\(session.id.uuidString)-right")
        #expect(buildPane(store, restored, role: .right) == nil)
        #expect(restored.zmxSplitKey == nil)
    }

    /// The label is not a rename-only effect: the retired `agterm-zmx-sync` is what used to keep it current,
    /// so without this every never-renamed row shows a bare uuid in `zmx list` and the pick list.
    @Test func wrappingAPaneLabelsItsSessionWithoutARename() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a/project")!
        buildPane(store, session, role: .left)
        buildPane(store, session, role: .right)
        #expect(spy.labelled.map(\.key)
                == ["\(session.id.uuidString)-left", "\(session.id.uuidString)-right"])
        #expect(spy.labelled.allSatisfy { $0.name == session.displayName })
    }

    // MARK: - the other teardown paths

    @Test func aGraceCloseEndsTheSessionOnlyWhenItFinalizes() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!)
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(spy.ended.isEmpty)
        store.finalizeAllPendingCloses()
        #expect(spy.ended == ["\(session.id.uuidString)-left"])
    }

    @Test func undoingAGraceCloseEndsNothing() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!)
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(store.undoPendingClose())
        #expect(spy.ended.isEmpty)
    }

    @Test func aGracefullyClosedWorkspaceEndsEverySessionInIt() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let first = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!)
        let second = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/b")!)
        _ = store.addWorkspace(name: "other") // the last workspace is never removable
        #expect(store.softRemoveWorkspace(workspace.id, grace: 60))
        #expect(spy.ended.isEmpty)
        store.finalizeAllPendingCloses()
        #expect(spy.ended == ["\(first.id.uuidString)-left", "\(second.id.uuidString)-left"])
    }

    @Test func removingAWorkspaceEndsEverySessionInIt() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let first = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!)
        let second = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/b")!)
        _ = store.addWorkspace(name: "other") // the last workspace is never removable
        store.removeWorkspace(workspace.id)
        #expect(spy.ended == ["\(first.id.uuidString)-left", "\(second.id.uuidString)-left"])
    }

    @Test func renamingARowLabelsBothItsPaneSessions() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = wrapSession(store.addSession(toWorkspace: workspace.id, cwd: "/a")!, split: true)
        store.toggleSplit(session.id)
        store.renameSession(session.id, to: "rebase")
        #expect(spy.labelled.map(\.key) == ["\(session.id.uuidString)-left", "\(session.id.uuidString)-right"])
        #expect(spy.labelled.allSatisfy { $0.name == "rebase" })
        #expect(spy.ended.isEmpty)
    }

    @Test func renamingAnUnwrappedRowLabelsNothing() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        session.initialCommand = "htop"
        store.renameSession(session.id, to: "top")
        #expect(spy.labelled.isEmpty)
    }

    // MARK: - windows

    /// ⚠️ The one mistake that would kill every agent in a window on ⌘W. A closed window keeps its session
    /// ids in `windows/<id>.json` and reopens with them, so its teardown must reach no zmx session at all.
    @Test func closingAWindowEndsNothing() throws {
        try withLibrary { library, spy in
            let windowID = library.windows[0].id
            let store = try #require(library.store(for: windowID))
            let session = try #require(store.workspaces.first?.sessions.first)
            wrapSession(session, split: true)
            store.toggleSplit(session.id)
            library.closeWindow(windowID)
            #expect(spy.ended.isEmpty)
            // and the row is still claimed by the persisted window, which is what makes ending it wrong
            let reopened = try #require(library.loadStore(for: windowID))
            #expect(reopened.workspaces.first?.sessions.first?.id == session.id)
        }
    }

    /// Deleting a window destroys its rows for good, so it is the one window path that DOES end them.
    @Test func deletingAnOpenWindowEndsItsSessions() throws {
        try withLibrary { library, spy in
            let doomed = library.newWindow()
            let store = try #require(library.store(for: doomed.id))
            let session = try #require(store.workspaces.first?.sessions.first)
            wrapSession(session, split: true)
            library.removeWindow(doomed.id)
            #expect(spy.ended == ["\(session.id.uuidString)-left", "\(session.id.uuidString)-right"])
        }
    }

    /// The same for a window whose store is not loaded: the keys come off its persisted snapshot.
    @Test func deletingAClosedWindowEndsTheSessionsItsSnapshotRecords() throws {
        try withLibrary { library, spy in
            let doomed = library.newWindow()
            let store = try #require(library.store(for: doomed.id))
            let session = try #require(store.workspaces.first?.sessions.first)
            wrapSession(session)
            store.save()
            library.closeWindow(doomed.id)
            #expect(spy.ended.isEmpty)
            library.removeWindow(doomed.id)
            #expect(spy.ended == ["\(session.id.uuidString)-left"])
        }
    }

    private func withLibrary(_ body: (WindowLibrary, ZmxSinkSpy) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-zmx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = ZmxSinkSpy()
        try body(WindowLibrary(directory: directory, zmx: spy.sink), spy)
    }
}
