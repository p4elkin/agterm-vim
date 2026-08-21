import Foundation
import Testing

@testable import agtermCore

/// The drawn-space translation the sidebar's drag path needs once parked rows can be hidden.
///
/// ⚠️ These cover an index-space divergence, not a feature: `NSOutlineView` indexes the children it was
/// GIVEN, which are filtered by `isRowVisible`, while `moveSessions(_:toWorkspace:at:)` indexes
/// `workspace.sessions`. The two were identical until hiding existed, so nothing reconciled them and a drag
/// silently reordered the model while the sidebar showed no change.
@MainActor
struct ParkedDrawnIndexTests {
    /// A workspace of five rows, the middle two parked, hidden, and nothing selected in it.
    private func hiddenMiddle() -> (AppStore, UUID, [UUID]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir))
        let workspace = store.addWorkspace(name: "w")
        var ids: [UUID] = []
        for name in ["A", "P0", "P1", "B", "C"] {
            guard let session = store.addSession(toWorkspace: workspace.id, cwd: "/\(name)") else {
                continue
            }
            ids.append(session.id)
        }
        store.setParked(true, forSession: ids[1])
        store.setParked(true, forSession: ids[2])
        store.hideParked = true
        // selection off the parked pair, so the selected-row exemption does not draw one of them
        store.selectSession(ids[3])
        return (store, workspace.id, ids)
    }

    @Test func drawnLocationCountsOnlyTheRowsTheSidebarShows() {
        let (store, workspace, ids) = hiddenMiddle()
        #expect(store.visibleSessionCount(inWorkspace: workspace) == 3)
        let drawn = store.visibleSessionLocation(ofSession: ids[3])
        #expect(drawn?.index == 1)
        #expect(store.sessionLocation(ofSession: ids[3])?.index == 3)
    }

    /// The measured failure: drawn [A, B, C], drag A below C, AppKit says 3. Read as a model index that
    /// lands A at slot 2 — behind both hidden rows — so the sidebar redraws identically while the stored
    /// order changed underneath it.
    @Test func aDragPastHiddenRowsAppendsInTheModelRatherThanLandingBehindThem() {
        let (store, workspace, ids) = hiddenMiddle()
        let destination = store.modelInsertionIndex(drawnDestination: 2, inWorkspace: workspace,
                                                    excluding: [ids[0]])
        #expect(destination == 4)
    }

    @Test func aDrawnDestinationResolvesToItsAnchorRowsModelIndex() {
        let (store, workspace, ids) = hiddenMiddle()
        // drawn [B, C] after A is lifted; landing on C means landing where C is in the model
        let destination = store.modelInsertionIndex(drawnDestination: 1, inWorkspace: workspace,
                                                    excluding: [ids[0]])
        #expect(destination == 3)
    }

    @Test func withNothingHiddenTheTranslationIsIdentity() {
        let (store, workspace, ids) = hiddenMiddle()
        store.hideParked = false
        for drawn in 0...4 {
            #expect(store.modelInsertionIndex(drawnDestination: drawn, inWorkspace: workspace,
                                              excluding: []) == drawn)
        }
        #expect(store.visibleSessionCount(inWorkspace: workspace) == 5)
        #expect(store.visibleSessionLocation(ofSession: ids[3])?.index == 3)
    }

    @Test func aDestinationPastTheLastDrawnRowAppends() {
        let (store, workspace, ids) = hiddenMiddle()
        #expect(store.modelInsertionIndex(drawnDestination: 99, inWorkspace: workspace,
                                          excluding: [ids[0]]) == 4)
    }

    @Test func anUnknownWorkspaceAnswersWithoutCrashing() {
        let (store, _, _) = hiddenMiddle()
        #expect(store.modelInsertionIndex(drawnDestination: 2, inWorkspace: UUID(), excluding: []) == 2)
    }
}
