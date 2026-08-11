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

    private func row(command: String? = nil, keepShellOpen: Bool = false, hasSplit: Bool = false) -> ZmxLifecycle.Row {
        ZmxLifecycle.Row(sessionID: id, pinnedCommand: command, keepShellOpen: keepShellOpen, hasSplit: hasSplit)
    }

    // MARK: - the predicate

    @Test func rowCloseEndsTheOnePaneKey() {
        #expect(ZmxLifecycle.keysToEnd(row(), close: .row) == [left])
    }

    @Test func rowCloseWithASplitEndsBothPaneKeys() {
        #expect(ZmxLifecycle.keysToEnd(row(hasSplit: true), close: .row) == [left, right])
    }

    @Test func splitCloseEndsOnlyTheSplitKey() {
        #expect(ZmxLifecycle.keysToEnd(row(hasSplit: true), close: .split) == [right])
        #expect(ZmxLifecycle.keysToEnd(row(), close: .split).isEmpty)
    }

    @Test func windowCloseEndsNothing() {
        #expect(ZmxLifecycle.keysToEnd(row(hasSplit: true), close: .window).isEmpty)
        #expect(ZmxLifecycle.keysToEnd(row(command: "claude", keepShellOpen: true, hasSplit: true),
                                       close: .window).isEmpty)
    }

    @Test func aCommandRowOwnsNothingBecauseItWasNeverWrapped() {
        #expect(ZmxLifecycle.keysToEnd(row(command: "htop"), close: .row).isEmpty)
        #expect(ZmxLifecycle.ownedKeys(row(command: "htop")).isEmpty)
        // its split pane is still a plain shell, and so still wrapped
        #expect(ZmxLifecycle.keysToEnd(row(command: "htop", hasSplit: true), close: .row) == [right])
    }

    @Test func keepShellOpenMakesACommandRowOwnItsKey() {
        #expect(ZmxLifecycle.keysToEnd(row(command: "claude", keepShellOpen: true), close: .row) == [left])
    }

    @Test func aBlankPinnedCommandCountsAsNone() {
        #expect(ZmxLifecycle.ownedKeys(row(command: "   ")) == [left])
        #expect(ZmxLifecycle.ownedKeys(row(command: "")) == [left])
    }

    // MARK: - the store

    @Test func closingARowEndsItsSessions() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        store.toggleSplit(session.id)
        store.closeSession(session.id)
        #expect(spy.ended == ["\(session.id.uuidString)-left", "\(session.id.uuidString)-right"])
    }

    @Test func closingTheSplitEndsOnlyTheSplitSession() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        store.toggleSplit(session.id)
        store.closeSplit(session.id)
        #expect(spy.ended == ["\(session.id.uuidString)-right"])
    }

    @Test func aGraceCloseEndsTheSessionOnlyWhenItFinalizes() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(spy.ended.isEmpty)
        store.finalizeAllPendingCloses()
        #expect(spy.ended == ["\(session.id.uuidString)-left"])
    }

    @Test func undoingAGraceCloseEndsNothing() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(store.undoPendingClose())
        #expect(spy.ended.isEmpty)
    }

    @Test func removingAWorkspaceEndsEverySessionInIt() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let first = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        let second = store.addSession(toWorkspace: workspace.id, cwd: "/b")!
        _ = store.addWorkspace(name: "other") // the last workspace is never removable
        store.removeWorkspace(workspace.id)
        #expect(spy.ended == ["\(first.id.uuidString)-left", "\(second.id.uuidString)-left"])
    }

    @Test func renamingARowLabelsBothItsPaneSessions() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        store.toggleSplit(session.id)
        store.renameSession(session.id, to: "rebase")
        #expect(spy.labelled.map(\.key) == ["\(session.id.uuidString)-left", "\(session.id.uuidString)-right"])
        #expect(spy.labelled.allSatisfy { $0.name == "rebase" })
        #expect(spy.ended.isEmpty)
    }

    @Test func renamingAnUnwrappedCommandRowLabelsNothing() {
        let spy = ZmxSinkSpy()
        let store = makeStore(zmx: spy.sink)
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        session.initialCommand = "htop"
        store.renameSession(session.id, to: "top")
        #expect(spy.labelled.isEmpty)
    }

    /// ⚠️ The one mistake that would kill every agent in a window on ⌘W. A closed window keeps its session
    /// ids in `windows/<id>.json` and reopens with them, so its teardown must reach no zmx session at all.
    @Test func closingAWindowEndsNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-zmx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = ZmxSinkSpy()
        let library = WindowLibrary(directory: directory, zmx: spy.sink)
        let windowID = library.windows[0].id
        let store = try #require(library.store(for: windowID))
        let session = try #require(store.workspaces.first?.sessions.first)
        store.toggleSplit(session.id)
        library.closeWindow(windowID)
        #expect(spy.ended.isEmpty)
        // and the row is still claimed by the persisted window, which is what makes ending it wrong
        let reopened = try #require(library.loadStore(for: windowID))
        #expect(reopened.workspaces.first?.sessions.first?.id == session.id)
    }
}
