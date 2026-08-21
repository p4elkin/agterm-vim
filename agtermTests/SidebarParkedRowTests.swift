import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Counts full-outline reloads so a test can prove a park took the per-workspace children reload.
private final class ReloadCountingOutlineView: SidebarOutlineView {
    var reloadDataCount = 0
    override func reloadData() {
        reloadDataCount += 1
        super.reloadData()
    }
}

/// Hosted coverage for the parked sidebar row: it draws at reduced contrast, a selected parked row keeps
/// the full-strength selection colors, unparking restores the row through the per-row reload, and under
/// `hideParked` the row leaves the outline entirely.
@MainActor
final class SidebarParkedRowTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: ReloadCountingOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-parked-row-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.orderOut(nil)
            window = nil
            outline = nil
            coordinator = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testAParkedRowDrawsDimmerThanALiveOne() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        buildSidebar(for: store)

        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()

        let parkedCell = try renderedCell(forSession: parked.id)
        let liveCell = try renderedCell(forSession: live.id)
        XCTAssertLessThan(try labelAlpha(parkedCell), try labelAlpha(liveCell),
                          "a parked row's name must draw at lower contrast than a live one's")
        XCTAssertLessThan(try iconAlpha(parkedCell), try iconAlpha(liveCell),
                          "the row icon must dim with the name, or the row reads half-parked")
    }

    func testSelectionWinsOverTheParkedDim() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        buildSidebar(for: store)

        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()

        let parkedCell = try renderedCell(forSession: parked.id)
        let liveCell = try renderedCell(forSession: live.id)
        // without this the assertions below pass on a cell that never learned it was parked, i.e. on the
        // feature being absent rather than on selection beating it
        XCTAssertTrue(parkedCell.parked, "the row builder must have marked the cell parked")
        XCTAssertFalse(liveCell.parked)
        parkedCell.setColors(selected: true)
        liveCell.setColors(selected: true)

        XCTAssertEqual(try labelAlpha(parkedCell), try labelAlpha(liveCell), accuracy: 0.0001,
                       "a selected parked row must stay as readable as any other selected row")
        XCTAssertEqual(try iconAlpha(parkedCell), try iconAlpha(liveCell), accuracy: 0.0001,
                       "the icon follows the same rule as the name on a selected row")
    }

    func testUnparkingRestoresTheRowContrast() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        buildSidebar(for: store)

        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()
        XCTAssertTrue(try renderedCell(forSession: parked.id).parked, "the row must be dimmed to begin with")
        store.setParked(false, forSession: parked.id)
        coordinator.reconcile()

        let parkedCell = try renderedCell(forSession: parked.id)
        let liveCell = try renderedCell(forSession: live.id)
        XCTAssertEqual(try labelAlpha(parkedCell), try labelAlpha(liveCell), accuracy: 0.0001,
                       "unparking must reload the row; a stale dim would outlive the mark")
    }

    // the flat flagged list renders sessions through the same branch as the tree, which is the reason the dim
    // is resolved there rather than in either caller
    func testTheFlaggedViewDimsAParkedRowToo() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        store.setFlag(true, forSession: live.id)
        store.setFlag(true, forSession: parked.id)
        buildSidebar(for: store)

        store.setParked(true, forSession: parked.id)
        store.setSidebarMode(.flagged)
        coordinator.reconcile()

        let parkedCell = try renderedCell(forSession: parked.id)
        let liveCell = try renderedCell(forSession: live.id)
        XCTAssertLessThan(try labelAlpha(parkedCell), try labelAlpha(liveCell))
    }

    func testHidingRemovesAParkedRowFromTheTree() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        store.selectSession(live.id)
        buildSidebar(for: store)

        store.applyParkedVisibility(.hide)
        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()

        XCTAssertFalse(rowExists(forSession: parked.id), "a hidden parked row must leave the outline")
        XCTAssertTrue(rowExists(forSession: live.id))
    }

    func testARevealedWorkspaceKeepsItsParkedRows() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        let owner = try XCTUnwrap(store.workspaces.first)
        store.selectSession(live.id)
        buildSidebar(for: store)

        store.applyParkedVisibility(.hide)
        store.applyParkedVisibility(.show, toWorkspace: owner.id)
        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()

        XCTAssertTrue(rowExists(forSession: parked.id),
                      "a workspace in the revealed set must keep drawing its parked rows")
    }

    func testTheSelectedRowSurvivesParkingUntilSelectionMoves() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        buildSidebar(for: store)

        store.applyParkedVisibility(.hide)
        store.selectSession(parked.id)
        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()
        XCTAssertTrue(rowExists(forSession: parked.id),
                      "parking the selected row must not vanish it while its pane is on screen")

        store.selectSession(live.id)
        coordinator.reconcile()
        XCTAssertFalse(rowExists(forSession: parked.id), "the row leaves the tree once the selection moves off it")
    }

    func testTheFlaggedViewHidesParkedRowsToo() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        store.setFlag(true, forSession: live.id)
        store.setFlag(true, forSession: parked.id)
        store.selectSession(live.id)
        buildSidebar(for: store)

        store.applyParkedVisibility(.hide)
        store.setParked(true, forSession: parked.id)
        store.setSidebarMode(.flagged)
        coordinator.reconcile()

        XCTAssertFalse(rowExists(forSession: parked.id), "the flat flagged list must filter like the tree")
        XCTAssertTrue(rowExists(forSession: live.id))
    }

    func testParkingReloadsOnlyTheAffectedWorkspaceChildren() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        let other = store.addWorkspace(name: "other")
        _ = try XCTUnwrap(store.addSession(toWorkspace: other.id, cwd: NSHomeDirectory()))
        store.selectSession(live.id)
        buildSidebar(for: store)

        store.applyParkedVisibility(.hide)
        coordinator.reconcile()
        let before = outline.reloadDataCount

        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()
        XCTAssertFalse(rowExists(forSession: parked.id))
        XCTAssertEqual(outline.reloadDataCount, before,
                       "a park must reload the owning workspace's children, not the whole outline")

        store.setParked(false, forSession: parked.id)
        coordinator.reconcile()
        XCTAssertTrue(rowExists(forSession: parked.id), "unparking brings the row back")
        XCTAssertEqual(outline.reloadDataCount, before)
    }

    func testAWorkspaceHoldingParkedRowsShowsADimParkedCount() throws {
        let store = try XCTUnwrap(library.activeStore)
        let parked = try addSession(to: store)
        let owner = try XCTUnwrap(store.workspaces.first)
        buildSidebar(for: store)

        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()

        let cell = try renderedCell(forWorkspace: owner.id)
        let suffix = try XCTUnwrap(cell.parkedSuffix)
        XCTAssertEqual(suffix.stringValue, "⏸ 1",
                       "a workspace holding one parked row must say so after its name")
        XCTAssertLessThan(try alpha(of: XCTUnwrap(suffix.textColor)),
                          try labelAlpha(cell),
                          "the count is an annotation and must draw dimmer than the name")
    }

    // keyed on the FACT, not on hideParked: the count must stay while the rows are hidden,
    // exactly like the focus-membership icon stays legible with the filter off
    func testTheParkedCountStaysWhileHiddenAndClearsOnUnpark() throws {
        let store = try XCTUnwrap(library.activeStore)
        let live = try XCTUnwrap(store.activeSession)
        let parked = try addSession(to: store)
        let owner = try XCTUnwrap(store.workspaces.first)
        store.selectSession(live.id)
        buildSidebar(for: store)

        store.applyParkedVisibility(.hide)
        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()
        XCTAssertFalse(rowExists(forSession: parked.id))
        XCTAssertEqual(try XCTUnwrap(renderedCell(forWorkspace: owner.id).parkedSuffix).stringValue, "⏸ 1",
                       "a hidden parked row must not disappear without trace from its workspace")

        store.setParked(false, forSession: parked.id)
        coordinator.reconcile()
        XCTAssertEqual(try XCTUnwrap(renderedCell(forWorkspace: owner.id).parkedSuffix).stringValue, "",
                       "unparking the last row must clear the count")
    }

    func testTheParkedCountDoesNotUseTheBadgeSlot() throws {
        let store = try XCTUnwrap(library.activeStore)
        let parked = try addSession(to: store)
        let owner = try XCTUnwrap(store.workspaces.first)
        buildSidebar(for: store)

        store.setParked(true, forSession: parked.id)
        coordinator.reconcile()

        let cell = try renderedCell(forWorkspace: owner.id)
        XCTAssertEqual(cell.badge.count, 0, "the badge slot carries the unseen roll-up, never the parked count")
        XCTAssertTrue(cell.badge.isHidden)
    }

    private func addSession(to store: AppStore) throws -> Session {
        let owner = try XCTUnwrap(store.workspaces.first)
        return try XCTUnwrap(store.addSession(toWorkspace: owner.id, cwd: NSHomeDirectory()))
    }

    private func labelAlpha(_ cell: SidebarCellView) throws -> CGFloat {
        try alpha(of: XCTUnwrap(cell.textField?.textColor))
    }

    private func iconAlpha(_ cell: SidebarCellView) throws -> CGFloat {
        try alpha(of: XCTUnwrap(cell.imageView?.contentTintColor))
    }

    /// A theme color can be a catalog color, whose components are unreadable until it is converted.
    private func alpha(of color: NSColor) -> CGFloat {
        color.usingColorSpace(.deviceRGB)?.alphaComponent ?? color.alphaComponent
    }

    private func rowExists(forSession id: UUID) -> Bool {
        outline.layoutSubtreeIfNeeded()
        return (0..<outline.numberOfRows).contains { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .session && node.id == id
        }
    }

    private func buildSidebar(for store: AppStore) {
        outline = ReloadCountingOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        // over-releases a window the registry may still hold, crashing the host at autorelease-pool pop
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }

    private func renderedCell(forSession id: UUID) throws -> SidebarCellView {
        try renderedCell(kind: .session, id: id)
    }

    private func renderedCell(forWorkspace id: UUID) throws -> SidebarCellView {
        try renderedCell(kind: .workspace, id: id)
    }

    private func renderedCell(kind: SidebarNode.Kind, id: UUID) throws -> SidebarCellView {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == kind && node.id == id
        }, "the row should be visible in the outline")
        return try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
    }
}
