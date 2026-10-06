import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class NewSessionButtonTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var settings: SettingsModel!
    private var window: NSWindow?
    private var outline: SidebarOutlineView?
    private var coordinator: WorkspaceSidebar.Coordinator?
    private var creates: [(host: String, workspace: UUID, store: AppStore)] = []
    private var pendingCreate: CheckedContinuation<RemoteCreateOutcome, Never>?
    private var failures: [(title: String, windowID: UUID)] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-plus-button-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        actions.settingsModel = settings
        actions.presentRemoteCreateFailure = { [weak self] title, _, windowID in self?.failures.append((title, windowID)) }
    }

    override func tearDown() async throws {
        pendingCreate?.resume(returning: .refused("torn down"))
        pendingCreate = nil
        window?.orderOut(nil)
        window = nil
        outline = nil
        coordinator = nil
        actions = nil
        settings = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func useHost(answer: @escaping @MainActor () async -> RemoteCreateOutcome) {
        settings.setNewSessionHost("p4linux")
        actions.createRemoteSession = { [weak self] host, workspace, store in
            self?.creates.append((host, workspace, store))
            return await answer()
        }
    }

    private func suspendedAnswer() async -> RemoteCreateOutcome {
        await withCheckedContinuation { pendingCreate = $0 }
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testWithAHostTheCreateGoesRemoteAndAddsNoLocalRow() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let target = store.addWorkspace(name: "target")
        let before = store.workspaces.flatMap(\.sessions).count
        useHost { .refused("stub") }

        await actions.newSessionFromButton(workspaceID: target.id, in: store)?.value

        XCTAssertEqual(creates.map(\.host), ["p4linux"])
        XCTAssertEqual(creates.map(\.workspace), [target.id])
        XCTAssertTrue(creates.first?.store === store)
        XCTAssertEqual(store.workspaces.flatMap(\.sessions).count, before)
    }

    func testASecondClickWhileOneIsPendingIsIgnoredAndTheNextOneRuns() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let windowID = try XCTUnwrap(library.windowID(for: store))
        useHost { await self.suspendedAnswer() }

        let first = actions.newSessionFromButton(workspaceID: workspace, in: store)
        await settle()
        XCTAssertNil(actions.newSessionFromButton(workspaceID: workspace, in: store))
        XCTAssertTrue(RemoteCreatePending.shared.contains(windowID))
        pendingCreate?.resume(returning: .refused("down"))
        pendingCreate = nil
        await first?.value

        XCTAssertFalse(RemoteCreatePending.shared.contains(windowID))
        XCTAssertEqual(creates.count, 1)
        useHost { .refused("down") }
        await actions.newSessionFromButton(workspaceID: workspace, in: store)?.value
        XCTAssertEqual(creates.count, 2)
    }

    func testFailuresReachThePresenterWithTheirOwnTitles() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let windowID = try XCTUnwrap(library.windowID(for: store))
        useHost { .refused("ssh: connect timed out") }
        await actions.newSessionFromButton(workspaceID: workspace, in: store)?.value
        useHost { .createdNotAttached(remoteID: "s1", error: "the workspace is gone") }
        await actions.newSessionFromButton(workspaceID: workspace, in: store)?.value

        XCTAssertEqual(failures.map(\.title), ["Could not create a session on p4linux",
                                               "A session was created on p4linux but could not be attached"])
        XCTAssertEqual(failures.map(\.windowID), [windowID, windowID])
        XCTAssertFalse(RemoteCreatePending.shared.contains(windowID))
    }

    func testWithoutAHostAddsALocalRowAtThePlacementIndexAndSelectsIt() throws {
        settings.setNewSessionPlacement(AppSettings.NewSessionPlacement.afterCurrent.rawValue)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.activeSession)
        _ = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp/second", select: false))
        store.selectSession(first.id)

        XCTAssertNil(actions.newSessionFromButton(workspaceID: workspace, in: store))

        let sessions = try XCTUnwrap(store.workspaces.first { $0.id == workspace }?.sessions)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[1].id, store.selectedSessionID)
        XCTAssertTrue(creates.isEmpty)
    }

    func testABackgroundWindowsButtonCreatesInThatWindow() throws {
        let background = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(background.currentWorkspaceID)
        let before = background.workspaces.flatMap(\.sessions).count
        library.newWindow(name: "front")
        XCTAssertFalse(library.activeStore === background)

        actions.newSessionFromButton(workspaceID: workspace, in: background)

        XCTAssertEqual(background.workspaces.flatMap(\.sessions).count, before + 1)
    }

    func testTheSidebarPlusIsDisabledWhileACreateIsPending() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        buildSidebar(for: store)
        useHost { await self.suspendedAnswer() }

        let task = actions.newSessionFromButton(workspaceID: workspace, in: store)
        await settle()
        coordinator?.reconcile()
        XCTAssertEqual(try plusButton(for: workspace).isEnabled, false)
        XCTAssertEqual(try newSessionMenuItem(for: workspace).isEnabled, false)

        pendingCreate?.resume(returning: .refused("down"))
        pendingCreate = nil
        await task?.value
        coordinator?.reconcile()
        XCTAssertEqual(try plusButton(for: workspace).isEnabled, true)
        XCTAssertEqual(try newSessionMenuItem(for: workspace).isEnabled, true)
    }

    private func row(for workspaceID: UUID) throws -> Int {
        let outline = try XCTUnwrap(outline)
        return try XCTUnwrap((0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? SidebarNode).map { $0.kind == .workspace && $0.id == workspaceID } ?? false
        })
    }

    private func plusButton(for workspaceID: UUID) throws -> NSButton {
        let row = try row(for: workspaceID)
        let cell = try XCTUnwrap(outline?.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        return try XCTUnwrap(cell.addButton)
    }

    private func newSessionMenuItem(for workspaceID: UUID) throws -> NSMenuItem {
        let menu = try XCTUnwrap(coordinator?.menu(forRow: try row(for: workspaceID)))
        return try XCTUnwrap(menu.items.first { $0.title == "New Session" })
    }

    private func buildSidebar(for store: AppStore) {
        let outline = SidebarOutlineView()
        let coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        // `NSWindow` defaults isReleasedWhenClosed to true; see the hosted-test rule in ui-tests.md.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
        self.window = window
        self.outline = outline
        self.coordinator = coordinator
    }
}
