import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerSurfaceIOTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-surface-io-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeServer() -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                      socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    private func makeSession(split: Bool) throws -> (store: AppStore, session: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        session.surface = realizedView(session: session)
        if split {
            store.toggleSplit(session.id)
            let right = realizedView(session: session)
            right.isSplitPane = true
            session.splitSurface = right
        }
        return (store, session)
    }

    private func addScratch(to session: Session) -> GhosttySurfaceView {
        let scratch = realizedView(session: nil)
        scratch.watermarkSession = session
        session.scratchSurface = scratch
        return scratch
    }

    private func realizedView(session: Session?, env: [String: String] = [:]) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: "/bin/cat", env: env)
        view.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        return view
    }

    private func set(_ server: ControlServer, _ session: Session, _ watermark: BackgroundWatermark?,
                     pane: StatusPane? = nil) -> ControlResponse {
        server.setSessionBackground(session.id.uuidString, window: nil,
                                    options: ControlSessionBackgroundOptions(watermark: watermark, pane: pane))
    }

    private func textFile(_ session: Session, key: String?) -> String {
        WatermarkStorage.renderedTextURL(sessionID: session.id, paneKey: key).path
    }

    func testAHiddenSplitsIDAnswersNotRealizedLikeItsRole() async throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: false)
        let (_, plain) = try makeSession(split: false)
        session.hasSplit = true
        let split = UUID()
        session.splitPaneIdentity = split
        let id = session.id.uuidString

        let byID = server.readSessionText(id, window: nil,
                                          options: ControlSessionTextOptions(pane: nil, paneID: split.uuidString, all: false, lines: nil))
        let byRole = server.readSessionText(id, window: nil, options: ControlSessionTextOptions(pane: .right, all: false, lines: nil))
        let typed = await server.typeSession(id, window: nil,
                                             options: ControlSessionTypeOptions(text: "x", select: false, pane: nil, paneID: split.uuidString))
        let pasted = await server.pasteSessionText(id, window: nil, pane: nil, paneID: split.uuidString, text: "x")
        let font = server.font(id, window: nil, pane: .right, action: "font.inc")
        let lead = server.takeSessionLead(id, window: nil, pane: .right)
        let noSplit = server.readSessionText(plain.id.uuidString, window: nil,
                                             options: ControlSessionTextOptions(pane: .right, all: false, lines: nil))

        XCTAssertEqual(byID.error, "session not realized")
        XCTAssertEqual(byRole.error, "session not realized")
        XCTAssertEqual(typed.error, "session not realized")
        XCTAssertEqual(pasted.error, "session not realized")
        XCTAssertEqual(font.error, "session not realized")
        XCTAssertEqual(lead.error, "session not realized")
        XCTAssertEqual(noSplit.error, "session has no split pane")
    }

    func testAPrimaryIDWithNoPrimarySurfaceIsNotPastedIntoTheSplit() async throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: true)
        session.surface = nil
        let id = session.id.uuidString

        let byID = await server.pasteSessionText(id, window: nil, pane: nil, paneID: session.paneIdentity.uuidString, text: "x")
        let bare = await server.pasteSessionText(id, window: nil, pane: nil, paneID: nil, text: "x")

        XCTAssertEqual(byID.error, "session not realized")
        XCTAssertTrue(bare.ok, "\(bare)")
    }

    func testAPaneOverrideNeedsThatPaneToExist() throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: false)
        let label = BackgroundWatermark(kind: .text, text: "PEER")

        XCTAssertEqual(set(server, session, label, pane: .right).error, "session has no split pane")
        XCTAssertEqual(set(server, session, label, pane: .scratch).error, "session has no scratch terminal")
        XCTAssertTrue(session.paneBackgrounds.isEmpty)
        XCTAssertTrue(set(server, session, label, pane: .left).ok)
        XCTAssertEqual(session.paneBackgrounds.left, label)
    }

    func testAPaneOverrideRendersToItsOwnFileAndLeavesTheDefaultAlone() throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: true)
        let rightKey = try XCTUnwrap(session.backgroundFileKey(for: .right))

        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)

        XCTAssertTrue(FileManager.default.fileExists(atPath: textFile(session, key: rightKey)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: nil)))
        XCTAssertNil(session.backgroundWatermark)
    }

    func testADefaultChangeReappliesOnlyInheritingPanes() throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: true)
        let left = try XCTUnwrap(session.surface as? GhosttySurfaceView)
        let right = try XCTUnwrap(session.splitSurface as? GhosttySurfaceView)
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .color, colorHex: "#102030"), pane: .right).ok)
        left.oscBackgroundColorHex = "#abcdef"
        right.oscBackgroundColorHex = "#abcdef"

        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .color, colorHex: "#201414")).ok)

        XCTAssertNil(left.oscBackgroundColorHex)
        XCTAssertEqual(right.oscBackgroundColorHex, "#abcdef")
    }

    func testAPaneTextFileGoesWithItsSplit() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: true)
        let rightKey = try XCTUnwrap(session.backgroundFileKey(for: .right))
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)

        store.closeSplit(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: rightKey)))
    }

    func testPromotionKeepsTheSurvivorsFileAndDropsTheExitingOnes() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: true)
        let leftKey = session.paneIdentity.uuidString
        let rightKey = try XCTUnwrap(session.backgroundFileKey(for: .right))
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "DRIVER"), pane: .left).ok)
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)

        store.closePrimaryPane(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: leftKey)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: textFile(session, key: rightKey)))
        XCTAssertEqual(session.backgroundFileKey(for: .left), rightKey)
    }

    func testAScratchTextFileGoesWithTheScratch() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: false)
        _ = addScratch(to: session)
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "SCRATCH"), pane: .scratch).ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: textFile(session, key: "scratch")))

        XCTAssertTrue(store.closeScratch(session.id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: "scratch")))
    }

    func testRepeatedLabelledSplitsLeaveNoTextFilesBehind() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: false)
        for _ in 0..<3 {
            store.toggleSplit(session.id)
            let right = realizedView(session: session)
            right.isSplitPane = true
            session.splitSurface = right
            XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)
            store.closeSplit(session.id)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: WatermarkStorage.directoryURL().path)
        XCTAssertFalse(names.contains { $0.hasPrefix(session.id.uuidString) })
    }

    // MARK: - an asleep remote row

    private final class ScreenRunner: RemoteCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        let result: RemoteCommandResult

        init(_ result: RemoteCommandResult) { self.result = result }

        var calls: [[String]] { lock.withLock { recorded } }

        func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
            lock.withLock { recorded.append(argv) }
            return result
        }
    }

    private struct AsleepFixture {
        let server: ControlServer
        let store: AppStore
        let row: Session
    }

    private var now = Date(timeIntervalSince1970: 5_000)
    private var sleeps = 0
    private var events: [ControlEvent] = []

    private func asleepRow(split: Bool = false, select: Bool = false,
                           runner: ScreenRunner = ScreenRunner(RemoteCommandResult(status: 0, stdout: "", stderr: ""))) throws -> AsleepFixture {
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                                   identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil, remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control.sock").path)
        server.hudClock = { [unowned self] in now }
        server.windowOnScreen = { _ in true }
        server.ptyWakeSleep = { [unowned self] in
            sleeps += 1
            now = now.addingTimeInterval($0)
        }
        library.onRowWake = { [weak server] in server?.wakeAttachLines(for: $0) }
        library.onControlEvent = { [unowned self] in events.append($0) }
        let store = try XCTUnwrap(library.activeStore)
        let row = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp", select: select,
                                                 remoteHost: "box"))
        var daemons = [row.paneIdentity: ZmxSupport.daemonName(for: UUID())]
        if split {
            store.toggleSplit(row.id)
            daemons[try XCTUnwrap(row.splitPaneIdentity)] = ZmxSupport.daemonName(for: UUID())
        }
        store.bindRemote(RemoteBinding(remoteSessionID: "s-\(UUID().uuidString)", daemonsByLocalPane: daemons, presentationVersion: 1,
                                       origin: .init(host: "box", endpoint: ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/zmx"),
                                                     sessionName: "build")),
                         forSession: row.id)
        addTeardownBlock { daemons.keys.forEach { ZmxLeadBook.shared.forget(pane: $0) } }
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .timer, now: now))
        return AsleepFixture(server: server, store: store, row: row)
    }

    /// attachOnFirstPause stands in for the deck and the origin: the woken pane mounts, then reports `role`.
    private func attachOnFirstPause(_ fixture: AsleepFixture, pane: StatusPane = .left, role: String = "leader",
                                    typed: @escaping () -> Void = {}) {
        let row = fixture.row
        fixture.server.ptyWakeSleep = { [unowned self] in
            sleeps += 1
            now = now.addingTimeInterval($0)
            guard sleeps == 1, let identity = pane == .left ? row.paneIdentity : row.splitPaneIdentity,
                  let nonce = ZmxLeadBook.shared.states[identity]?.attachment.nonce,
                  let notice = ZmxLeadNotice(title: "zmx-role;\(nonce):\(role):1") else { return }
            let view = realizedView(session: row, env: ["AGTERM_PANE_ID": identity.uuidString])
            view.onUserInputClearsStatus = { _ in typed() }
            if pane == .left { row.surface = view } else {
                view.isSplitPane = true
                row.splitSurface = view
            }
            _ = ZmxLeadBook.shared.apply(notice, pane: identity)
        }
    }

    private func woke(_ row: Session) -> [String?] {
        events.filter { $0.kind == .sessionWoke && $0.session == row.id.uuidString }.map(\.payload.reason)
    }

    func testTypeToAnAsleepRowWakesItWaitsForThePanesFirstLeadReportAndTypesOnce() async throws {
        let fixture = try asleepRow()
        var typed = 0
        attachOnFirstPause(fixture) { typed += 1 }

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionType, target: fixture.row.id.uuidString,
                                                                    args: ControlArgs(text: "ls")))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(typed, 1)
        XCTAssertEqual(sleeps, 1, "the command ran on the pause that brought the report")
        XCTAssertFalse(fixture.row.asleep)
        XCTAssertEqual(woke(fixture.row), ["pty"])
        XCTAssertEqual(fixture.row.offScreenSince, Date(timeIntervalSince1970: 5_000), "an unselected row's clock restarts")
    }

    func testTypeToTheActiveAsleepRowReachesItThoughTheSelectionMovesDuringTheWait() async throws {
        let fixture = try asleepRow(select: true)
        let other = try XCTUnwrap(fixture.store.addSession(toWorkspace: try XCTUnwrap(fixture.store.currentWorkspaceID),
                                                           cwd: NSTemporaryDirectory(), select: false))
        let otherView = realizedView(session: other)
        other.surface = otherView
        var typed: [String] = []
        otherView.onUserInputClearsStatus = { _ in typed.append("other") }
        attachOnFirstPause(fixture) { typed.append("asleep") }
        let attach = fixture.server.ptyWakeSleep
        fixture.server.ptyWakeSleep = { [store = fixture.store] in
            await attach($0)
            store.selectedSessionID = other.id
        }

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionType, target: "active", args: ControlArgs(text: "ls")))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(fixture.store.selectedSessionID, other.id)
        XCTAssertEqual(typed, ["asleep"])
    }

    func testAWokenCommandPinsAnExplicitWindowToTheRowsOwn() async throws {
        let fixture = try asleepRow(select: true)
        attachOnFirstPause(fixture)
        var args = ControlArgs(text: "ls")
        args.window = "active"
        var request = ControlRequest(cmd: .sessionType, target: "active", args: args)

        let refusal = await fixture.server.asleepRowResponse(&request)

        XCTAssertNil(refusal)
        XCTAssertEqual(request.target, fixture.row.id.uuidString)
        XCTAssertEqual(request.args?.window, library.windowID(for: fixture.store)?.uuidString)
    }

    func testCursorOnTheActiveAsleepSurfaceReadsItThoughTheSelectionMovesDuringTheWait() async throws {
        let fixture = try asleepRow(select: true)
        let other = try XCTUnwrap(fixture.store.addSession(toWorkspace: try XCTUnwrap(fixture.store.currentWorkspaceID),
                                                           cwd: NSTemporaryDirectory(), select: false))
        other.surface = realizedView(session: other)
        attachOnFirstPause(fixture)
        let attach = fixture.server.ptyWakeSleep
        fixture.server.ptyWakeSleep = { [store = fixture.store] in
            await attach($0)
            store.selectedSessionID = other.id
        }

        let response = await fixture.server.dispatch(ControlRequest(cmd: .surfaceCursor, target: "active"))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, "surface:\(fixture.row.id.uuidString):left")
    }

    func testTypeToAnAsleepRowFailsAfterTheBoundedWaitAndTypesNothing() async throws {
        let fixture = try asleepRow()

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionType, target: fixture.row.id.uuidString,
                                                                    args: ControlArgs(text: "ls")))

        XCTAssertEqual(response.error, "session.type: the row was asleep and its left pane did not attach within 20 s; "
                       + "the command did not run")
        XCTAssertLessThanOrEqual(abs(sleeps - Int(ControlServer.ptyWakeTimeout / ControlServer.ptyWakePoll)), 1, "\(sleeps) pauses")
        XCTAssertNil(fixture.row.surface)
        XCTAssertFalse(fixture.row.asleep, "the wake stands; the pane attaches on its own time")
    }

    func testAPaneAnotherMacLeadsEndsTheWaitAndTheCommandAnswersInItsOwnWords() async throws {
        let fixture = try asleepRow()
        var typed = 0
        attachOnFirstPause(fixture, role: "follower") { typed += 1 }

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionType, target: fixture.row.id.uuidString,
                                                                    args: ControlArgs(text: "ls")))

        XCTAssertEqual(response.error, "pane is in use on the Mac it runs on; take the lead to drive it from here")
        XCTAssertEqual(typed, 0)
    }

    func testAWokenRowWithNothingToAttachFailsAtOnce() async throws {
        let fixture = try asleepRow()
        fixture.store.setRemoteRowState(.endedOnHost, forSession: fixture.row.id)

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionPaste, target: fixture.row.id.uuidString))

        XCTAssertEqual(response.error, "session.paste: the row was asleep and its left pane has nothing to attach; "
                       + "the command did not run")
        XCTAssertEqual(sleeps, 0)
    }

    func testEveryPaneCommandWakesAnAsleepSplitRowFirstAndWaitsForThePaneItNames() async throws {
        let left: [(AsleepFixture) -> ControlRequest] = [
            { ControlRequest(cmd: .sessionType, target: $0.row.id.uuidString, args: ControlArgs(text: "ls")) },
            { ControlRequest(cmd: .sessionPaste, target: $0.row.id.uuidString) },
            { ControlRequest(cmd: .sessionSelectAll, target: $0.row.id.uuidString) },
            { ControlRequest(cmd: .sessionCopy, target: $0.row.id.uuidString) },
            { ControlRequest(cmd: .sessionLead, target: $0.row.id.uuidString) },
            { ControlRequest(cmd: .fontInc, target: $0.row.id.uuidString) },
            { ControlRequest(cmd: .fontDec, target: $0.row.id.uuidString) },
            { ControlRequest(cmd: .fontReset, target: $0.row.id.uuidString) },
            { ControlRequest(cmd: .surfaceCursor, target: "surface:\($0.row.id.uuidString):left") },
            { ControlRequest(cmd: .surfaceCursor, target: $0.row.id.uuidString, args: ControlArgs(paneID: $0.row.paneIdentity.uuidString)) },
        ]
        let right: [(AsleepFixture) -> ControlRequest] = [
            { ControlRequest(cmd: .sessionType, target: $0.row.id.uuidString, args: ControlArgs(text: "ls", pane: "right")) },
            { ControlRequest(cmd: .sessionPaste, target: $0.row.id.uuidString, args: ControlArgs(pane: "right")) },
            { ControlRequest(cmd: .sessionLead, target: $0.row.id.uuidString, args: ControlArgs(pane: "right")) },
            { ControlRequest(cmd: .fontInc, target: $0.row.id.uuidString, args: ControlArgs(pane: "right")) },
            { ControlRequest(cmd: .surfaceCursor, target: "surface:\($0.row.id.uuidString):right") },
            { ControlRequest(cmd: .sessionSearch, target: $0.row.id.uuidString, args: ControlArgs(text: "err")) },
        ]
        for (pane, requests) in [("left", left), ("right", right)] {
            for make in requests {
                let fixture = try asleepRow(split: true)
                let request = make(fixture)
                events = []

                let response = await fixture.server.dispatch(request)

                let waited = "\(request.cmd.rawValue): the row was asleep and its \(pane) pane did not attach"
                XCTAssertTrue(response.error?.hasPrefix(waited) == true, "\(waited) / \(response.error ?? "ok")")
                XCTAssertEqual(woke(fixture.row), ["pty"], request.cmd.rawValue)
            }
        }
    }

    func testARightPaneCommandWaitsForTheSplitAndActsOnIt() async throws {
        let fixture = try asleepRow(split: true)
        attachOnFirstPause(fixture, pane: .right)

        let response = await fixture.server.dispatch(ControlRequest(cmd: .fontInc, target: fixture.row.id.uuidString,
                                                                    args: ControlArgs(pane: "right")))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNotNil(fixture.row.splitSurface)
    }

    func testARightPaneCommandOnAHiddenSplitNoSleepReleasedAnswersAtOnceWithoutAWake() async throws {
        let fixture = try asleepRow(split: true)
        fixture.store.setSplitVisibility(fixture.row.id, shown: false)

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionType, target: fixture.row.id.uuidString,
                                                                    args: ControlArgs(text: "ls", pane: "right")))

        XCTAssertEqual(response.error, "session has no split pane")
        XCTAssertEqual(sleeps, 0)
        XCTAssertTrue(fixture.row.asleep)
    }

    func testTheScratchOfAnAsleepRowAnswersWithoutAWake() async throws {
        let fixture = try asleepRow()
        _ = addScratch(to: fixture.row)

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionType, target: fixture.row.id.uuidString,
                                                                    args: ControlArgs(text: "ls", pane: "scratch")))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(fixture.row.asleep)
    }

    func testTextOnAnAsleepRowReadsTheOriginsScreenAndLeavesItAsleep() async throws {
        let runner = ScreenRunner(RemoteCommandResult(status: 0, stdout: "7 80 24 3 2 0\n$ make\nok\n\n", stderr: ""))
        let fixture = try asleepRow(split: true, runner: runner)
        let split = try XCTUnwrap(fixture.row.splitPaneIdentity)
        let daemon = try XCTUnwrap(fixture.row.remotePresentation?.binding.daemon(forLocalPane: split))

        let screen = await fixture.server.dispatch(ControlRequest(cmd: .sessionText, target: fixture.row.id.uuidString,
                                                                  args: ControlArgs(pane: "right")))
        let tail = await fixture.server.dispatch(ControlRequest(cmd: .sessionText, target: fixture.row.id.uuidString,
                                                                args: ControlArgs(pane: "right", lines: 1)))

        XCTAssertEqual(screen.result?.text, "$ make\nok\n\n")
        XCTAssertEqual(screen.result?.pane, "right")
        XCTAssertEqual(tail.result?.text, "ok")
        let calls = runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.contains("box"), true)
        XCTAssertTrue(calls.allSatisfy { argv in !argv.contains { $0.hasPrefix("ControlPath") } }, "no pool lease: \(calls)")
        XCTAssertEqual(calls.map { $0.last?.contains("'screen' '\(daemon)'") }, [true, true])
        XCTAssertEqual(calls.map { $0.last?.hasSuffix("'--all'") }, [false, true])
        XCTAssertTrue(fixture.row.asleep)
        XCTAssertEqual(woke(fixture.row), [])
        XCTAssertEqual(sleeps, 0)
    }

    func testTextOnAnAsleepRowSaysWhyTheOriginCouldNotBeRead() async throws {
        let runner = ScreenRunner(RemoteCommandResult(status: 255, stdout: "", stderr: "ssh: connect to host box: timed out\n"))
        let fixture = try asleepRow(runner: runner)

        let response = await fixture.server.dispatch(ControlRequest(cmd: .sessionText, target: fixture.row.id.uuidString))

        XCTAssertEqual(response.error, "session.text: the row is asleep and its screen on box could not be read: "
                       + "ssh: connect to host box: timed out")
        XCTAssertTrue(fixture.row.asleep)
    }

    func testEveryCommandThatMayWakeOrReadTheOriginRunsOffTheAcceptThread() {
        for cmd in PtyWake.commands.union([.sessionText]) {
            XCTAssertTrue(ControlServer.waitsOnNetwork(cmd), cmd.rawValue)
        }
    }
}
