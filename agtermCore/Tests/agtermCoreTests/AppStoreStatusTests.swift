import Foundation
import Testing
@testable import agtermCore

@MainActor
private final class DraftCollector {
    var kinds: [ControlEventKind] = []
    var payloads: [ControlEventPayload] = []
}

/// The `tree` projection of the agent-status change time, and the pane-precedence rule over a blocked
/// status. The stamping itself is covered by `AppStoreTests`' `setAgentIndicator` cases; these cover what
/// a control client reads back.
@MainActor
struct AppStoreStatusTests {
    @Test func controlTreeReportsStatusChangedAtAsEpochSeconds() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.statusChangedAt == session.statusChangedAt?.timeIntervalSince1970)
        // pinned against the wall clock, not only against the source: the field ships for comparison with
        // `ControlEvent.ts`, so a monotonic stamp would satisfy the equality above and still be unusable.
        let now = Date().timeIntervalSince1970
        let stamp = try #require(node.statusChangedAt)
        #expect(stamp > now - 60 && stamp <= now)
    }

    @Test func controlTreeReportsStatusChangedAtWhenIdle() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        #expect(store.controlTree().workspaces[0].sessions[0].statusChangedAt == nil)
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        #expect(store.controlTree().workspaces[0].sessions[0].statusChangedAt != nil)

        session.statusChangedAt = Date(timeIntervalSince1970: 0)
        let before = Date().timeIntervalSince1970
        store.setAgentIndicator(AgentIndicator(status: .idle), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.status == nil)
        let stamp = try #require(node.statusChangedAt)
        #expect(stamp == session.statusChangedAt?.timeIntervalSince1970)
        #expect(stamp >= before)
    }

    @Test func controlTreeRefreshesStatusChangedAtOnARePushOfTheSameStatus() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: 0) // pretend the glyph went stale
        let stale = try #require(store.controlTree().workspaces[0].sessions.first?.statusChangedAt)

        // an unchanged status is what the hooks re-push on every tool event; the age must still reset
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)

        let fresh = try #require(store.controlTree().workspaces[0].sessions.first?.statusChangedAt)
        #expect(fresh > stale)
    }

    // MARK: - the status note

    private func noteStore() -> (AppStore, Session, DraftCollector) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let drafts = DraftCollector()
        let store = AppStore(persistence: PersistenceStore(directory: dir), controlEventSink: {
            drafts.kinds.append($0.kind)
            drafts.payloads.append($0.payload)
        })
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        return (store, session, drafts)
    }

    @Test func aStatusWithoutANoteClearsTheStandingOne() {
        let (store, session, _) = noteStore()
        store.setAgentIndicator(AgentIndicator(status: .active, note: "tool: Bash"), forSession: session.id)
        #expect(session.agentIndicator.note == "tool: Bash")

        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)

        #expect(session.agentIndicator.note == nil)
    }

    @Test func aNoteOnlyChangeKeepsTheStampAndEmitsAStatusEvent() {
        let (store, session, drafts) = noteStore()
        store.setAgentIndicator(AgentIndicator(status: .blocked, note: "perm: Bash"), forSession: session.id)
        let stamp = Date(timeIntervalSince1970: 1_000)
        session.statusChangedAt = stamp
        drafts.payloads.removeAll()

        store.setAgentIndicator(AgentIndicator(status: .blocked, note: "ask: which branch"), forSession: session.id)

        #expect(session.statusChangedAt == stamp)
        #expect(drafts.payloads.count == 1)
        #expect(drafts.payloads.first?.note == "ask: which branch")
        #expect(drafts.payloads.first?.status == "blocked")
        #expect(drafts.payloads.first?.previous == "blocked")
    }

    @Test func anIdenticalRepeatWithItsNoteRestampsAndEmitsNothing() {
        let (store, session, drafts) = noteStore()
        store.setAgentIndicator(AgentIndicator(status: .active, note: "tool: Bash"), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: 1_000)
        drafts.payloads.removeAll()

        store.setAgentIndicator(AgentIndicator(status: .active, note: "tool: Bash"), forSession: session.id)

        #expect(session.statusChangedAt != Date(timeIntervalSince1970: 1_000))
        #expect(drafts.payloads.isEmpty)
    }

    @Test func aStateChangeKeepingTheNoteRestamps() {
        let (store, session, _) = noteStore()
        store.setAgentIndicator(AgentIndicator(status: .active, note: "turn: tests"), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: 1_000)

        store.setAgentIndicator(AgentIndicator(status: .completed, note: "turn: tests"), forSession: session.id)

        #expect(session.statusChangedAt != Date(timeIntervalSince1970: 1_000))
    }

    @Test func clearingTheNoteAloneKeepsTheStamp() {
        let (store, session, drafts) = noteStore()
        store.setAgentIndicator(AgentIndicator(status: .active, note: "tool: Bash"), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: 1_000)
        drafts.payloads.removeAll()

        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)

        #expect(session.statusChangedAt == Date(timeIntervalSince1970: 1_000))
        #expect(drafts.payloads.count == 1)
        #expect(drafts.payloads.first?.note == nil)
    }

    @Test func anIdleWriteStoresNoNote() {
        let (store, session, drafts) = noteStore()
        store.setAgentIndicator(AgentIndicator(status: .idle, note: "stray"), forSession: session.id)

        #expect(session.agentIndicator.note == nil)
        #expect(drafts.payloads.allSatisfy { $0.note == nil })
    }

    @Test func anotherPanesWriteOverBlockedKeepsTheOwnersNote() {
        let (store, session) = blockedLeftSplitSession()
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left, note: "perm: Edit"),
                                 forSession: session.id)

        let result = store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right, note: "tool: Read"),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.note == "perm: Edit")
    }

    @Test func visitingAnAutoResetRowClearsItsNote() throws {
        let (store, session, _) = noteStore()
        let ws = try #require(store.workspace(forSession: session.id))
        let other = try #require(store.addSession(toWorkspace: ws.id, cwd: "/other"))
        store.selectSession(other.id)
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true, note: "turn: done"),
                                forSession: session.id)

        store.selectSession(session.id)

        #expect(session.agentIndicator.status == .idle)
        #expect(session.agentIndicator.note == nil)
    }

    // MARK: - pane precedence over a blocked status

    /// A split session whose LEFT pane holds a blocked status — the two-agent shape the rule exists for.
    private func blockedLeftSplitSession() -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.toggleSplit(session.id)
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        return (store, session)
    }

    @Test(arguments: [AgentStatus.active, .completed, .idle])
    func aWriteFromTheOtherPaneKeepsTheLeftPanesBlockShown(_ status: AgentStatus) {
        let (store, session) = blockedLeftSplitSession()
        let stamp = session.statusChangedAt

        let result = store.applyControlStatus(AgentIndicator(status: status, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .blocked)
        #expect(session.agentIndicator.statusPane == .left)
        #expect(session.statusChangedAt == stamp)
        #expect((session.paneActivity[.right] != nil) == (status == .active))
    }

    @Test(arguments: [AgentStatus.active, .completed, .idle])
    func theOwningPaneChangesItsOwnBlock(_ status: AgentStatus) {
        let (store, session) = blockedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: status, statusPane: .left),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == status)
    }

    @Test func anUntaggedWriterCountsAsTheLeftPane() {
        let (store, session) = blockedLeftSplitSession()

        #expect(store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id) == .applied)
        #expect(session.agentIndicator.status == .active)
    }

    @Test func theOtherPanesOwnBlockReplacesTheStandingOne() {
        let (store, session) = blockedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.statusPane == .right)
    }

    // the bundled hooks emit `idle` unprompted from their own pane — Codex's `session-start` and the shell
    // integration's `precmd` — so an exempt cross-pane idle would let starting an agent wipe the sibling's block.
    @Test func theOwningPaneStillClearsItsBlockWithIdle() {
        let (store, session) = blockedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: .idle, statusPane: .left),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .idle)
    }

    // a raw pane comparison rejects this: the writer's `.right` is what a promoted survivor's shell keeps
    // baked, and the setter stores it as `.left` — the pane it is now.
    @Test func aStaleRightTagOnASplitlessSessionOwnsTheBlockItSet() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        #expect(session.agentIndicator.statusPane == .left)

        let result = store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .active)
    }

    @Test func markForAttentionSetsAPlainCompletedOnAnIdleSession() throws {
        let drafts = DraftCollector()
        let store = AppStore(persistence: PersistenceStore(directory: FileManager.default.temporaryDirectory
                                 .appendingPathComponent("agterm-tests-\(UUID().uuidString)")),
                             controlEventSink: { drafts.kinds.append($0.kind) })
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        drafts.kinds.removeAll()

        store.markForAttention([session.id])

        #expect(session.agentIndicator == AgentIndicator(status: .completed))
        #expect(store.attentionSessions.map(\.id) == [session.id])
        #expect(drafts.kinds == [.status])
        let node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.status == "completed")
        #expect(node.statusChangedAt == session.statusChangedAt?.timeIntervalSince1970)
        #expect(node.statusChangedAt != nil)
    }

    @Test func markForAttentionSurvivesLeavingAndRevisitingTheSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let marked = try #require(store.addSession(toWorkspace: ws.id, cwd: "/marked"))
        let other = try #require(store.addSession(toWorkspace: ws.id, cwd: "/other"))
        store.selectSession(marked.id)

        store.markForAttention([marked.id])
        store.selectSession(other.id)
        store.selectSession(marked.id)

        #expect(marked.agentIndicator.status == .completed)
    }

    @Test(arguments: [AgentStatus.active, .completed, .blocked])
    func markForAttentionLeavesANonIdleSessionAlone(_ status: AgentStatus) throws {
        let drafts = DraftCollector()
        let store = AppStore(persistence: PersistenceStore(directory: FileManager.default.temporaryDirectory
                                 .appendingPathComponent("agterm-tests-\(UUID().uuidString)")),
                             controlEventSink: { drafts.kinds.append($0.kind) })
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let standing = AgentIndicator(status: status, blink: true, color: "#112233", statusPane: .left)
        store.setAgentIndicator(standing, forSession: session.id)
        let stamp = session.statusChangedAt
        drafts.kinds.removeAll()

        store.markForAttention([session.id])

        #expect(session.agentIndicator == standing)
        #expect(session.statusChangedAt == stamp)
        #expect(drafts.kinds.isEmpty)
    }

    @Test func markForAttentionMarksOnlyTheIdleMembersOfABatch() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let idle = try #require(store.addSession(toWorkspace: ws.id, cwd: "/idle"))
        let blocked = try #require(store.addSession(toWorkspace: ws.id, cwd: "/blocked"))
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: blocked.id)

        store.markForAttention([idle.id, blocked.id, UUID()])

        #expect(idle.agentIndicator.status == .completed)
        #expect(blocked.agentIndicator.status == .blocked)
    }

    @Test func aWriteUnderTheOtherPanesBlockEmitsNoStatusEvent() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let drafts = DraftCollector()
        let store = AppStore(persistence: PersistenceStore(directory: dir),
                             controlEventSink: { drafts.kinds.append($0.kind) })
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.toggleSplit(session.id)
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        #expect(drafts.kinds.contains(.status))
        drafts.kinds.removeAll()

        store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right), forSession: session.id)

        #expect(drafts.kinds.isEmpty)
    }

    // MARK: - pane precedence over a sticky completed status

    /// A split session whose LEFT pane holds a `completed` written without auto-reset: an open question.
    private func stickyCompletedLeftSplitSession(autoReset: Bool = false) -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.toggleSplit(session.id)
        store.applyControlStatus(AgentIndicator(status: .completed, autoReset: autoReset, statusPane: .left,
                                                note: "asks: which option?"),
                                 forSession: session.id)
        return (store, session)
    }

    @Test(arguments: [AgentStatus.active, .completed, .idle])
    func rightPaneCannotReplaceTheLeftPanesStickyCompleted(_ status: AgentStatus) {
        let (store, session) = stickyCompletedLeftSplitSession()
        let stamp = session.statusChangedAt

        let result = store.applyControlStatus(AgentIndicator(status: status, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .completed)
        #expect(session.agentIndicator.note == "asks: which option?")
        #expect(session.statusChangedAt == stamp)
    }

    @Test func theOtherPanesBlockReplacesAStickyCompleted() {
        let (store, session) = stickyCompletedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .blocked)
        #expect(session.agentIndicator.statusPane == .right)
    }

    @Test(arguments: [AgentStatus.active, .completed, .idle])
    func theOwningPaneChangesItsOwnStickyCompleted(_ status: AgentStatus) {
        let (store, session) = stickyCompletedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: status, statusPane: .left),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == status)
    }

    @Test func anAutoResetCompletedIsNotOwned() {
        let (store, session) = stickyCompletedLeftSplitSession(autoReset: true)

        let result = store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .active)
        #expect(session.agentIndicator.statusPane == .right)
    }

    @Test func aSinglePaneRowReplacesItsStickyCompleted() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.applyControlStatus(AgentIndicator(status: .completed, statusPane: .left), forSession: session.id)

        let result = store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .active)
    }

    @Test func anIfIdleWriteAppliesOnAnIdleRow() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))

        let result = store.applyControlStatus(AgentIndicator(status: .active, blink: true), forSession: session.id,
                                              ifIdle: true)

        #expect(result == .applied)
        #expect(session.agentIndicator == AgentIndicator(status: .active, blink: true))
    }

    @Test(arguments: [AgentStatus.active, .completed, .blocked])
    func anIfIdleWriteLeavesABusyRowUntouched(_ standing: AgentStatus) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let drafts = DraftCollector()
        let store = AppStore(persistence: PersistenceStore(directory: dir),
                             controlEventSink: { drafts.kinds.append($0.kind) })
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.applyControlStatus(AgentIndicator(status: standing), forSession: session.id)
        let stamp = session.statusChangedAt
        drafts.kinds.removeAll()

        let result = store.applyControlStatus(AgentIndicator(status: .active, blink: true), forSession: session.id,
                                              ifIdle: true)

        #expect(result == .skipped)
        #expect(session.agentIndicator == AgentIndicator(status: standing))
        #expect(session.statusChangedAt == stamp)
        #expect(drafts.kinds.isEmpty)
    }

    @Test func anIfIdleWriteFromTheOtherPaneIsSkippedAndRecordsNoActivity() {
        let (store, session) = blockedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right),
                                              forSession: session.id, ifIdle: true)

        #expect(result == .skipped)
        #expect(session.agentIndicator.status == .blocked)
        #expect(session.paneActivity.isEmpty)
    }

    private func splitSession() -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.toggleSplit(session.id)
        return (store, session)
    }

    private func post(_ status: AgentStatus, _ pane: StatusPane, _ store: AppStore, _ session: Session) {
        store.applyControlStatus(AgentIndicator(status: status, blink: status == .active, statusPane: pane), forSession: session.id)
    }

    // the incident: codex's turn end in the right pane idled the row while Claude's background shell still ran
    @Test(arguments: [AgentStatus.completed, .idle])
    func anotherPanesTurnEndLeavesTheRowOnTheWorkingPane(_ end: AgentStatus) {
        let (store, session) = splitSession()
        post(.active, .left, store, session)

        post(end, .right, store, session)

        #expect(session.agentIndicator == AgentIndicator(status: .active, blink: true, statusPane: .left))
    }

    @Test(arguments: [(StatusPane.left, StatusPane.right, StatusPane.right, StatusPane.left),
                      (.right, .left, .right, .left), (.left, .right, .left, .right)])
    func aPaneFinishingAfterBothStartedLeavesTheRowOnTheOther(_ first: StatusPane, _ second: StatusPane,
                                                              _ finishing: StatusPane, _ working: StatusPane) {
        let (store, session) = splitSession()
        post(.active, first, store, session)
        post(.active, second, store, session)

        post(.completed, finishing, store, session)

        #expect(session.agentIndicator.status == .active)
        #expect(session.agentIndicator.statusPane == working)
        #expect(Array(session.paneActivity.keys) == [working])
    }

    @Test func aPaneFinishingWithNoOtherWorkShowsItsCompletion() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)

        post(.completed, .left, store, session)

        #expect(session.agentIndicator.status == .completed)
        #expect(session.paneActivity.isEmpty)
    }

    @Test func aCompletionUnderTheOtherPanesBlockIsNotBroughtBackWhenTheBlockEnds() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)
        post(.blocked, .right, store, session)
        post(.completed, .left, store, session)

        post(.idle, .right, store, session)

        #expect(session.agentIndicator.status == .idle)
    }

    @Test func workStartedUnderTheOtherPanesBlockShowsWhenTheBlockEnds() {
        let (store, session) = splitSession()
        post(.blocked, .right, store, session)
        post(.active, .left, store, session)

        post(.idle, .right, store, session)

        #expect(session.agentIndicator == AgentIndicator(status: .active, blink: true, statusPane: .left))
    }

    @Test func aKeystrokeClearingABlockShowsTheOtherPanesWork() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)
        post(.blocked, .right, store, session)

        store.clearStatus(by: .other, pane: .right, reset: .firstKey, forSession: session.id)

        #expect(session.agentIndicator == AgentIndicator(status: .active, blink: true, statusPane: .left))
    }

    // an Esc in a pane the row did not show left its cancelled turn to come back when the shown pane finished
    @Test func anInterruptInAPaneTheRowDoesNotShowEndsThatPanesWork() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)
        post(.active, .right, store, session)

        store.clearStatus(by: .interrupt, pane: .left, reset: .firstKey, forSession: session.id)
        #expect(session.agentIndicator.statusPane == .right)
        post(.completed, .right, store, session)

        #expect(session.agentIndicator.status == .completed)
    }

    @Test func typingInAPaneTheRowDoesNotShowKeepsThatPanesWork() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)
        post(.active, .right, store, session)

        store.clearStatus(by: .submit, pane: .left, reset: .firstKey, forSession: session.id)

        #expect(session.paneActivity[.left] != nil)
        #expect(session.agentIndicator.statusPane == .right)
    }

    @Test func aManualClearEndsEveryPanesWork() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)
        post(.active, .right, store, session)

        store.clearStatus(session.id)

        #expect(session.agentIndicator.status == .idle)
        #expect(session.paneActivity.isEmpty)
    }

    @Test func aSelectionAutoResetEndsOnlyTheShownPanesWork() {
        let (store, session) = splitSession()
        post(.active, .right, store, session)
        store.applyControlStatus(AgentIndicator(status: .active, autoReset: true, statusPane: .left), forSession: session.id)

        store.clearStatus(session.id, reason: .select)

        #expect(session.agentIndicator == AgentIndicator(status: .active, blink: true, statusPane: .right))
    }

    @Test func reselectingTheSelectedSessionEndsOnlyTheShownPanesAutoResetWork() {
        let (store, session) = splitSession()
        store.selectSession(session.id)
        store.applyControlStatus(AgentIndicator(status: .active, autoReset: true, statusPane: .right), forSession: session.id)
        store.applyControlStatus(AgentIndicator(status: .active, autoReset: true, statusPane: .left), forSession: session.id)

        store.selectSession(session.id)

        #expect(session.agentIndicator.status == .active)
        #expect(session.agentIndicator.statusPane == .right)
    }

    @Test func aRawIdleSetEndsEveryPanesWork() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)

        store.setAgentIndicator(AgentIndicator(), forSession: session.id)
        post(.completed, .right, store, session)

        #expect(session.agentIndicator.status == .completed)
        #expect(session.paneActivity.isEmpty)
    }

    @Test func aPresenterSelectionEndsOnlyTheShownPanesWork() {
        let (store, session) = splitSession()
        post(.active, .right, store, session)
        store.applyControlStatus(AgentIndicator(status: .active, autoReset: true, statusPane: .left), forSession: session.id)

        store.applyPresenterClear(PresentationStatusClear(reason: .select), forSession: session.id, reset: .firstKey)

        #expect(session.agentIndicator.statusPane == .right)
    }

    @Test func aPresenterInterruptInAPaneTheRowDoesNotShowEndsThatPanesWork() {
        let (store, session) = splitSession()
        post(.active, .left, store, session)
        post(.active, .right, store, session)

        store.applyPresenterClear(PresentationStatusClear(reason: .interrupt, pane: .identity(session.paneIdentity)),
                                  forSession: session.id, reset: .firstKey)

        #expect(session.paneActivity[.left] == nil)
        #expect(session.agentIndicator.statusPane == .right)
    }

    @Test func controlTreeReportsTheWorkingPanesInPaneOrder() throws {
        let (store, session) = splitSession()
        #expect(store.controlTree().workspaces[0].sessions[0].activePanes == [])

        post(.active, .right, store, session)
        post(.active, .left, store, session)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.activePanes == ["left", "right"])
        #expect(node.statusPane == "left")
    }

    @MainActor
    private final class RecordingSink: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}

        var statuses: [PresentationStatus?] {
            frames.compactMap { if case .status(let status) = $0.body { return .some(status) } else { return nil } }
        }
    }

    private func mirroredStore() throws -> (AppStore, Session, RecordingSink) {
        let store = makeStore()
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.toggleSplit(session.id)
        let sink = RecordingSink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: [], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }
        return (store, session, sink)
    }

    @Test func aStatusWriteReachesTheHubAsFullStateWithItsOwnerPaneAndGlyphOverrides() throws {
        let (store, session, sink) = try mirroredStore()
        let split = try #require(session.splitPaneIdentity)

        store.applyControlStatus(AgentIndicator(status: .blocked, blink: true, color: "#ff8800", shape: .star,
                                                statusPane: .right), forSession: session.id)

        let status = try #require(sink.statuses.last ?? nil)
        #expect(status.status == .blocked)
        #expect(status.blink)
        #expect(status.color == "#ff8800")
        #expect(status.shape == .star)
        #expect(status.pane == .identity(split))
        #expect(status.changedAt == session.statusChangedAt?.timeIntervalSince1970)
    }

    @Test(arguments: [StatusPane.left, .scratch, nil])
    func theOwnerPaneTravelsAsAnIdentityOrScratch(_ pane: StatusPane?) throws {
        let (store, session, sink) = try mirroredStore()

        store.applyControlStatus(AgentIndicator(status: .active, statusPane: pane), forSession: session.id)

        let expected: PresentationPane = pane == .scratch ? .scratch : .identity(session.paneIdentity)
        #expect((sink.statuses.last ?? nil)?.pane == expected)
    }

    @Test func idleReachesTheHubAsAnAbsentStatus() throws {
        let (store, session, sink) = try mirroredStore()
        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .idle), forSession: session.id)

        #expect(sink.statuses.count == 2)
        #expect(sink.statuses.last == .some(nil))
    }

    @Test func workUnderTheOtherPanesBlockReachesTheHubOnlyWhenItStartsOrEnds() throws {
        let (store, session, sink) = try mirroredStore()
        let split = try #require(session.splitPaneIdentity)
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right), forSession: session.id)
        store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right), forSession: session.id)
        #expect(sink.statuses.count == 2)
        #expect((sink.statuses.last ?? nil)?.status == .blocked)
        #expect((sink.statuses.last ?? nil)?.activePanes == [.identity(split)])

        store.applyControlStatus(AgentIndicator(status: .completed, statusPane: .right), forSession: session.id)
        #expect(sink.statuses.count == 3)
        #expect((sink.statuses.last ?? nil)?.activePanes == [])
    }

    @Test func aSkippedWritePublishesNothing() throws {
        let (store, session, sink) = try mirroredStore()
        store.applyControlStatus(AgentIndicator(status: .completed), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id, ifIdle: true)

        #expect(sink.statuses.count == 1)
    }

    @Test func aRepeatedIdenticalWriteRepublishesTheRestampedState() throws {
        let (store, session, sink) = try mirroredStore()

        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: 1)
        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id)

        #expect(sink.statuses.count == 2)
        #expect((sink.statuses.last ?? nil)?.changedAt == session.statusChangedAt?.timeIntervalSince1970)
        #expect((sink.statuses.last ?? nil)?.changedAt != 1)
    }

    @Test func theSnapshotOfAnIdleSessionHasNoStatus() throws {
        let (store, session, _) = try mirroredStore()

        #expect(store.presentationSnapshot(forSession: session.id).status == nil)
    }

    private func blockedSession(split: Bool = false, autoReset: Bool = false) throws -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        if split { store.toggleSplit(session.id) }
        store.setAgentIndicator(AgentIndicator(status: .blocked, autoReset: autoReset, statusPane: .left), forSession: session.id)
        return (store, session)
    }

    @Test(arguments: [(PresentationClearReason.key, StatusReset.firstKey, true), (.key, .enter, false), (.submit, .enter, true),
                      (.interrupt, .enter, true), (.submit, .never, false)])
    func aPresenterKeystrokeClearsUnderTheOriginsReset(_ reason: PresentationClearReason, _ reset: StatusReset, _ cleared: Bool) throws {
        let (store, session) = try blockedSession()

        store.applyPresenterClear(PresentationStatusClear(reason: reason, pane: .identity(session.paneIdentity)),
                                  forSession: session.id, reset: reset)

        #expect((session.agentIndicator.status == .idle) == cleared)
    }

    // the presenter's own Status reset travels with its keystroke and wins over the origin's
    @Test(arguments: [(PresentationClearReason.key, StatusReset.never, StatusReset.firstKey, false),
                      (.submit, .never, .firstKey, false), (.interrupt, .never, .firstKey, false),
                      (.key, .firstKey, .never, true), (.submit, .enter, .never, true), (.key, .enter, .firstKey, false)])
    func aPresenterKeystrokeClearsUnderThePresentersResetWhenItSendsOne(
        _ reason: PresentationClearReason, _ sent: StatusReset, _ origin: StatusReset, _ cleared: Bool
    ) throws {
        let (store, session) = try blockedSession()

        store.applyPresenterClear(PresentationStatusClear(reason: reason, pane: .identity(session.paneIdentity), reset: sent),
                                  forSession: session.id, reset: origin)

        #expect((session.agentIndicator.status == .idle) == cleared)
    }

    @Test func aPresenterKeystrokeInAnotherPaneOrNoPaneOfTheSessionChangesNothing() throws {
        let (store, session) = try blockedSession(split: true)
        let split = try #require(session.splitPaneIdentity)

        for pane in [PresentationPane.identity(split), .identity(UUID()), .scratch] {
            store.applyPresenterClear(PresentationStatusClear(reason: .submit, pane: pane), forSession: session.id, reset: .firstKey)
        }
        store.applyPresenterClear(PresentationStatusClear(reason: .submit), forSession: session.id, reset: .firstKey)

        #expect(session.agentIndicator.status == .blocked)
    }

    @Test func aPresenterSelectionClearsOnlyAnAutoResetStatusAndAManualClearAlways() throws {
        let (store, session) = try blockedSession()
        let (autoStore, autoSession) = try blockedSession(autoReset: true)

        store.applyPresenterClear(PresentationStatusClear(reason: .select), forSession: session.id, reset: .firstKey)
        autoStore.applyPresenterClear(PresentationStatusClear(reason: .select), forSession: autoSession.id, reset: .firstKey)
        #expect(session.agentIndicator.status == .blocked)
        #expect(autoSession.agentIndicator.status == .idle)

        store.applyPresenterClear(PresentationStatusClear(reason: .manual), forSession: session.id, reset: .never)
        #expect(session.agentIndicator.status == .idle)
    }

    @Test(arguments: [(PresentationClearReason.viewed, StatusReset.never, true), (.key, .firstKey, true), (.key, .enter, false),
                      (.submit, .enter, true), (.key, .never, false), (.manual, .firstKey, false)])
    func aPresenterSeenLowersTheBadgeUnderTheOriginsBadgeReset(_ reason: PresentationClearReason, _ reset: StatusReset,
                                                               _ cleared: Bool) throws {
        let (store, session) = try blockedSession()
        session.unseenCount = 2

        store.applyPresenterSeen(PresentationSeen(reason: reason), forSession: session.id, badgeReset: reset)

        #expect((session.unseenCount == 0) == cleared)
    }

    @Test func aClearOrSeenWithAnUnknownReasonChangesNothing() throws {
        let (store, session) = try blockedSession()
        session.unseenCount = 1
        let clear = try JSONDecoder().decode(PresentationStatusClear.self, from: Data(#"{"reason":"wave"}"#.utf8))
        let seen = try JSONDecoder().decode(PresentationSeen.self, from: Data(#"{"reason":"wave"}"#.utf8))

        store.applyPresenterClear(clear, forSession: session.id, reset: .firstKey)
        store.applyPresenterSeen(seen, forSession: session.id, badgeReset: .firstKey)

        #expect(session.agentIndicator.status == .blocked)
        #expect(session.unseenCount == 1)
    }

    @Test func aClearedOriginStatusIsGoneFromTheNextSnapshot() throws {
        let (store, session) = try blockedSession()

        store.applyPresenterClear(PresentationStatusClear(reason: .manual), forSession: session.id, reset: .firstKey)

        #expect(store.presentationSnapshot(forSession: session.id, now: Date()).status == nil)
    }

    @Test func clearStatusOnALocalRowSendsNothing() throws {
        let (store, session) = try blockedSession()
        var sent: [PresentationFrame.Body] = []
        store.onOriginFrame = { _, body in
            sent.append(body)
            return true
        }

        store.clearStatus(session.id)

        #expect(session.agentIndicator.status == .idle)
        #expect(sent.isEmpty)
    }
}
