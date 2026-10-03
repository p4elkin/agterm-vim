import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteForwardTests: XCTestCase {
    private var stateDir: URL!
    private var servers: [ControlServer] = []
    private var pickWindows: [WindowInfo.ID] = []

    private struct Fixture {
        let server: ControlServer
        let library: WindowLibrary
        let store: AppStore
        let row: Session
        let serverSession: String
        let other: Session
        let otherServerSession: String
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-forward-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for id in pickWindows { PickRegistry.shared.unregister(id) }
        pickWindows.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        HtmlOverlayRegistry.shared.setZoom(1)
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func fixture() throws -> Fixture {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-rf-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        func remoteRow(boundTo serverSession: String) throws -> Session {
            let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "p4linux"))
            store.bindRemote(RemoteBinding(remoteSessionID: serverSession, daemonsByLocalPane: [:], presentationVersion: 1),
                             forSession: session.id)
            return session
        }
        let serverSession = UUID().uuidString
        let otherServerSession = UUID().uuidString
        return Fixture(server: server, library: library, store: store, row: try remoteRow(boundTo: serverSession),
                       serverSession: serverSession, other: try remoteRow(boundTo: otherServerSession),
                       otherServerSession: otherServerSession)
    }

    private func request(_ command: Command, target: String?, _ edit: (inout ControlArgs) -> Void = { _ in }) -> ControlRequest {
        var args = ControlArgs()
        edit(&args)
        return ControlRequest(cmd: command, target: target, args: args)
    }

    func testAFlagNamingTheServerSessionFlagsThisRowAndAnswersWithTheServerID() async throws {
        let fix = try fixture()

        let response = await fix.server.runForwarded(request(.sessionFlag, target: fix.serverSession) { $0.mode = "on" },
                                                     forSession: fix.row.id)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, fix.serverSession)
        XCTAssertTrue(fix.row.flagged)
        XCTAssertFalse(fix.other.flagged)
    }

    func testATargetThatIsNotThisRowsServerSessionIsRefused() async throws {
        let fix = try fixture()

        for target in [fix.otherServerSession, UUID().uuidString, fix.row.id.uuidString, "active", nil] as [String?] {
            let response = await fix.server.runForwarded(request(.sessionFlag, target: target) { $0.mode = "on" },
                                                         forSession: fix.row.id)

            XCTAssertEqual(response.error, "forwarded session.flag refused: the target is not the session this row presents",
                           "\(target ?? "nil")")
        }
        XCTAssertFalse(fix.row.flagged)
        XCTAssertFalse(fix.other.flagged)
    }

    func testARequestThePolicyRefusesOrOneCarryingACommandIsRefused() async throws {
        let fix = try fixture()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-forward-must-not-run-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let refused = [
            request(.sessionScratch, target: fix.serverSession) { $0.mode = "on" },
            request(.sessionOverlayOpen, target: fix.serverSession) { $0.command = "touch \(marker)" },
            request(.sessionOverlayResult, target: fix.serverSession),
            request(.windowNew, target: nil),
        ]

        for forwarded in refused {
            let response = await fix.server.runForwarded(forwarded, forSession: fix.row.id)

            XCTAssertEqual(response.error, "forwarded \(forwarded.cmd.rawValue) refused: this Mac does not run it for an origin")
        }
        let withCommand = await fix.server.runForwarded(
            request(.sessionFlag, target: fix.serverSession) { $0.mode = "on"; $0.command = "touch \(marker)" },
            forSession: fix.row.id)
        XCTAssertEqual(withCommand.error, "forwarded session.flag refused: it carries a command")
        XCTAssertFalse(fix.row.flagged)
        XCTAssertFalse(fix.row.scratchActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testAForwardedURLOpenAnswersWithAPageID() async throws {
        let fix = try fixture()

        let response = await fix.server.runForwarded(
            request(.sessionOverlayOpen, target: fix.serverSession) { $0.url = "https://example.com" }, forSession: fix.row.id)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, fix.serverSession)
        XCTAssertNotNil(response.result?.pageID)
        fix.store.closeOverlay(fix.row.id)
    }

    func testCloseAndResizeWithNoJobOnTheMacAreRunHere() async throws {
        let fix = try fixture()

        for command in [Command.sessionOverlayClose, .sessionOverlayResize] {
            let response = await fix.server.runForwarded(request(command, target: fix.serverSession) { $0.sizePercent = 50 },
                                                         forSession: fix.row.id)

            XCTAssertFalse(response.error?.hasPrefix("forwarded ") ?? false, response.error ?? "")
        }
    }

    func testAPickOpensInTheWindowHoldingTheRow() async throws {
        let fix = try fixture()
        let rowWindow = try XCTUnwrap(fix.library.windowID(for: fix.store))
        let controller = PickController()
        PickRegistry.shared.register(rowWindow, controller: controller)
        pickWindows.append(rowWindow)
        _ = fix.library.newWindow(name: "frontmost")

        let response = await fix.server.runForwarded(
            request(.pickOpen, target: fix.serverSession) { $0.items = [ControlPickItem(id: "a", label: "A")] },
            forSession: fix.row.id)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(controller.pending?.id, response.result?.id)
    }

    func testPollsReachTheDispatcherWithTheirIDUntouched() async throws {
        let fix = try fixture()
        let page = UUID().uuidString

        let pick = await fix.server.runForwarded(request(.pickResult, target: "pick-from-this-mac"), forSession: fix.row.id)
        let cancel = await fix.server.runForwarded(request(.pickCancel, target: "pick-from-this-mac"), forSession: fix.row.id)
        let poll = await fix.server.runForwarded(request(.sessionOverlayResult, target: nil) { $0.page = page },
                                                 forSession: fix.row.id)

        XCTAssertEqual(pick.error, "unknown pick: pick-from-this-mac")
        XCTAssertEqual(cancel.error, "unknown pick: pick-from-this-mac")
        XCTAssertEqual(poll.error, OverlayHtmlError.unknownPage)
    }

    func testTheClientEffectRunsTheExecutor() async throws {
        let fix = try fixture()
        let answered = expectation(description: "reply")
        var reply: ControlResponse?

        let effects = try XCTUnwrap(fix.server.remoteEffects(for: fix.row.id).controlForward)
        effects(request(.sessionFlag, target: fix.serverSession) { $0.mode = "on" }) {
            reply = $0
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)

        XCTAssertEqual(reply?.ok, true)
        XCTAssertTrue(fix.row.flagged)
    }
}
