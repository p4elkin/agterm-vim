import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
struct HeadlessActionsTests {
    @Test func theOriginRefusesARebasedOnCloseCommand() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let response = await fixture.actions.respond(to: ControlRequest(cmd: .sessionOverlayOpen,
            target: fixture.session.id.uuidString, args: ControlArgs(rebased: true, onClose: "/bin/flush")))
        #expect(!response.ok)
        #expect(response.error?.contains("--on-close works on a local row only") == true)
        #expect(fixture.session.rebasedPlacement == nil)
    }

    @Test func treeAndWindowsExposeTheModel() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.node().id == fixture.session.id.uuidString)
        let windows = try await fixture.dispatch(.windowList)
        #expect(windows.result?.windows?.map(\.id) == fixture.headless.library.windows.map { $0.id.uuidString })
        #expect(fixture.store.presentationHub === fixture.headless.hub)
    }

    @Test func remoteTreeAndInventoryJoinTheDaemonWithItsOwner() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.ok(fixture.listing))
        fixture.runner.enqueue(.ok(fixture.listing))

        let tree = try await fixture.dispatch(.zmxTree)
        let inventory = try await fixture.dispatch(.zmxList)

        #expect(tree.result?.remote?.sessions.first?.id == fixture.session.id.uuidString)
        #expect(tree.result?.remote?.sessions.first?.panes.first?.daemon == ZmxSupport.daemonName(for: fixture.session.paneIdentity))
        #expect(inventory.result?.zmx?.entries.first?.state == "claimed")
        #expect(inventory.result?.zmx?.entries.first?.observation == "running")
        #expect(inventory.result?.zmx?.endpoint == fixture.headless.config.endpoint)
        #expect(fixture.runner.calls.map(\.arguments) == [["list"], ["list"]])
    }

    @Test func remoteTreeRefusesAHostWithoutRunningZmx() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.zmxTree) { $0.host = "elsewhere" }

        #expect(!response.ok)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test(arguments: [ZmxResult.timedOut, .failed(3, "boom"), .launchFailed("missing"), .ok("invalid listing")])
    func daemonListFailuresAreErrors(_ result: ZmxResult) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(result)
        fixture.runner.enqueue(result)

        #expect(try await fixture.dispatch(.zmxTree).ok == false)
        #expect(try await fixture.dispatch(.zmxList).ok == false)
    }

    @Test func statusContextAndSeenReadBackThroughTree() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.session.unseenCount = 2

        #expect(try await fixture.dispatch(.sessionStatus) { $0.status = "active" }.ok)
        #expect(try await fixture.node().status == "active")
        #expect(try await fixture.dispatch(.sessionContext) { $0.mode = "set"; $0.text = "building" }.ok)
        #expect(try await fixture.node().context == "building")
        #expect(try await fixture.node().unseen == 2)
        #expect(try await fixture.dispatch(.sessionSeen).ok)
        #expect(try await fixture.node().unseen == nil)
        #expect(try await fixture.dispatch(.sessionContext) { $0.mode = "clear" }.ok)
        #expect(try await fixture.node().context == nil)
    }

    @Test func aStatusNoteReadsBackAndAnotherPanesRefusedWriteKeepsIt() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionStatus) { $0.status = "blocked"; $0.note = "perm: Bash" }.ok)
        #expect(try await fixture.node().statusNote == "perm: Bash")
        fixture.session.hasSplit = true
        let refused = try await fixture.dispatch(.sessionStatus) {
            $0.status = "active"; $0.pane = "right"; $0.note = "tool: Read"
        }

        #expect(!refused.ok)
        #expect(try await fixture.node().statusNote == "perm: Bash")
    }

    @Test func marksAdvanceAndReadBack() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionMark).result?.count == 1)
        #expect(try await fixture.dispatch(.sessionMark).result?.count == 2)
        #expect(try await fixture.node().turn == 2)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func notificationAppearsInTheEventRing() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let baseline = try await fixture.dispatch(.eventsRead)
        let cursor = try #require(baseline.result?.events)
        #expect(try await fixture.dispatch(.notify) { $0.title = "build"; $0.body = "finished" }.ok)
        let events = try await fixture.dispatch(.eventsRead) {
            $0.run = cursor.run.uuidString
            $0.after = String(cursor.next)
        }
        let notification = try #require(events.result?.events?.items.first { $0.kind == .notify })
        #expect(notification.payload.title == "build")
        #expect(notification.payload.body == "finished")
        #expect(notification.session == fixture.session.id.uuidString)
        #expect(try await fixture.node().unseen == 1)
    }

    @Test(arguments: [nil, "abc123\n", "unknown\n", "\n"])
    func identityReadsTheInstallBuild(_ build: String?) async throws {
        let fixture = try HeadlessActionFixture(build: build)
        defer { fixture.cleanUp() }

        let version = try await fixture.dispatch(.version)
        let tree = try await fixture.dispatch(.tree)
        #expect(version.result?.app?.version == "headless")
        #expect(version.result?.app?.commit == (build == "abc123\n" ? "abc123" : nil))
        #expect(tree.result?.tree?.app == version.result?.app)
    }

    @Test func presentationValidatesBeforeTheSocketIsAdopted() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.zmxPresent)
        #expect(response == ControlResponse(ok: true, result: ControlResult(id: fixture.session.id.uuidString)))
        #expect(fixture.streams.adopted.isEmpty)
        #expect(fixture.actions.adoptPresentation(session: fixture.session.id.uuidString, connection: 123) == nil)
        #expect(fixture.streams.adopted.count == 1)
        #expect(fixture.streams.adopted.first?.0 == fixture.session.id)
        #expect(fixture.streams.adopted.first?.1 == 123)
    }

    @Test func presentationRejectsAMissingOrUnbackedSession() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.session.surface = nil

        #expect(try await fixture.dispatch(.zmxPresent).ok == false)
        #expect(fixture.actions.adoptPresentation(session: fixture.session.id.uuidString, connection: 123)?.ok == false)
        #expect(try await fixture.dispatch(.zmxPresent, target: UUID().uuidString).ok == false)
        #expect(fixture.streams.adopted.isEmpty)
    }

    @Test func newSessionUsesTheRunnerAndBecomesLiveBacked() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.sessionNew) { $0.name = "worker"; $0.command = "true" }
        let id = try #require(response.result?.id.flatMap(UUID.init(uuidString:)))
        let session = try #require(fixture.store.session(withID: id))
        #expect(session.allPanesBackedByZmx)
        #expect(fixture.runner.calls.first?.arguments == ["run", ZmxSupport.daemonName(for: session.paneIdentity), "-d", "sh", "-c", "true"])
    }

    @Test func newSessionUsesTheRequestedDirectoryAndReportsIt() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.sessionNew) { $0.cwd = "/tmp"; $0.command = "true" }
        let id = try #require(response.result?.id.flatMap(UUID.init(uuidString:)))
        let session = try #require(fixture.store.session(withID: id))
        let tree = try await fixture.dispatch(.tree)
        let node = tree.result?.tree?.workspaces.flatMap(\.sessions).first { $0.id == id.uuidString }

        #expect(fixture.runner.calls.first?.workingDirectory == "/tmp")
        #expect(session.initialCwd == "/tmp")
        #expect(node?.cwd == "/tmp")
    }

    @Test func aBareSessionRunsTrueInTheHomeDirectory() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.sessionNew)
        let id = try #require(response.result?.id.flatMap(UUID.init(uuidString:)))
        let session = try #require(fixture.store.session(withID: id))

        #expect(session.allPanesBackedByZmx)
        #expect(session.initialCwd == NSHomeDirectory())
        #expect(fixture.runner.calls.first?.workingDirectory == NSHomeDirectory())
        #expect(fixture.runner.calls.first?.arguments == ["run", ZmxSupport.daemonName(for: session.paneIdentity), "-d", "sh", "-c", "true"])
    }

    @Test func aRelativeDirectoryResolvesAgainstTheServerDirectory() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path

        let response = try await fixture.dispatch(.sessionNew) { $0.cwd = "." }
        let id = try #require(response.result?.id.flatMap(UUID.init(uuidString:)))

        #expect(fixture.store.session(withID: id)?.initialCwd == expected)
        #expect(fixture.runner.calls.first?.workingDirectory == expected)
    }

    @Test(arguments: ["missing", "file", "", "nul"])
    func invalidDirectoriesCreateNeitherSessionNorDaemon(_ kind: String) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("file")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        let cwd: String
        switch kind {
        case "": cwd = ""
        case "nul": cwd = "/tmp\0unexpected"
        default: cwd = fixture.directory.appendingPathComponent(kind).path
        }

        let response = try await fixture.dispatch(.sessionNew) { $0.cwd = cwd; $0.command = "true" }

        #expect(!response.ok)
        #expect(response.error?.contains("directory") == true)
        #expect(fixture.runner.calls.isEmpty)
        #expect(fixture.store.workspaces.flatMap(\.sessions).map(\.id) == [fixture.session.id])
    }

    @Test func newSessionGetsItsOwnPaneEnvironmentAndPasswordDatabaseShell() async throws {
        let fixture = try HeadlessActionFixture(shellLookup: { "/bin/test-login-shell" })
        defer { fixture.cleanUp() }

        let response = try await fixture.dispatch(.sessionNew) { $0.name = "t"; $0.command = "true" }
        let id = try #require(response.result?.id.flatMap(UUID.init(uuidString:)))
        let session = try #require(fixture.store.session(withID: id))
        let call = try #require(fixture.runner.calls.first)

        #expect(call.arguments == ["run", ZmxSupport.daemonName(for: session.paneIdentity), "-d", "sh", "-c", "true"])
        #expect(call.environment == [
            "SHELL": "/bin/test-login-shell",
            "AGTERM_ENABLED": "1",
            "AGTERM_SESSION_ID": id.uuidString,
            "AGTERM_SOCKET": fixture.headless.config.socketPath,
            "AGTERM_STATE_DIR": fixture.headless.config.stateDirectory,
            "AGTERM_PANE": "left",
            "AGTERM_PANE_ID": session.paneIdentity.uuidString,
            "AGTERM_WINDOW_ID": try #require(fixture.headless.library.windowID(for: fixture.store)).uuidString,
            "AGTERM_WORKSPACE_ID": try #require(fixture.store.workspace(forSession: id)).id.uuidString,
            "TERM_PROGRAM": "agterm",
            "TERM_PROGRAM_VERSION": "headless",
        ])
        #expect(session.effectiveCwd == NSHomeDirectory())
        #expect(call.workingDirectory == NSHomeDirectory())
    }

    @Test(arguments: [nil, ""])
    func missingPasswordDatabaseShellFallsBackToSh(_ shell: String?) async throws {
        let fixture = try HeadlessActionFixture(shellLookup: { shell })
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionNew) { $0.command = "true" }.ok)
        #expect(fixture.runner.calls.first?.environment["SHELL"] == "/bin/sh")
    }

    @Test func failedCreateRemovesTheSessionAndCleansUpTheDaemon() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.timedOut)

        let response = try await fixture.dispatch(.sessionNew) { $0.command = "true" }

        #expect(!response.ok)
        #expect(fixture.store.workspaces.flatMap(\.sessions).map(\.id) == [fixture.session.id])
        #expect(fixture.runner.calls.count == 2)
        #expect(fixture.runner.calls[1].arguments == ["kill", fixture.runner.calls[0].arguments[1], "--force"])
    }

    @Test func explicitUnknownTargetsNeverMutateTheDefaultSession() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.dispatch(.sessionMark, target: UUID().uuidString).ok == false)
        #expect(try await fixture.dispatch(.sessionStatus) { $0.status = "active"; $0.window = UUID().uuidString }.ok == false)
        #expect(try await fixture.dispatch(.tree) { $0.window = UUID().uuidString }.ok == false)
        #expect(fixture.session.turnCounter == 0)
        #expect(fixture.session.agentIndicator.status == .idle)
    }

    @Test func zmxNewCreatesThroughTheSessionPathAndIsAttachableAtOnce() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let request = HeadlessRequests.request(.zmxNew) {
            $0.name = "new"; $0.command = "echo ready"; $0.cwd = fixture.directory.path
        }

        let response = await fixture.actions.respond(to: request)

        #expect(response.ok)
        let id = try #require(response.result?.id)
        let (_, session) = try #require(fixture.headless.resolve(id))
        #expect(session.id != fixture.session.id)
        #expect(session.customName == "new")
        #expect(session.allPanesBackedByZmx)
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        #expect(fixture.runner.calls.first?.arguments == ["run", daemon, "-d", "sh", "-c", "echo ready"])
        #expect(fixture.runner.calls.first?.workingDirectory == fixture.directory.path)
        #expect(fixture.runner.calls.first?.environment["AGTERM_SESSION_ID"] == id)
        fixture.runner.enqueue(.ok("name=\(daemon)\tpid=42\tclients=0\n"))

        let tree = try await fixture.dispatch(.zmxTree)

        #expect(tree.ok)
        #expect(tree.result?.remote?.sessions.map(\.id) == [id])
    }

    @Test func aFailedZmxNewUsesTheExistingCreationCleanup() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.runner.enqueue(.timedOut)

        let response = await fixture.actions.respond(to: HeadlessRequests.request(.zmxNew) { $0.command = "false" })

        #expect(!response.ok)
        #expect(fixture.store.workspaces.flatMap(\.sessions).map(\.id) == [fixture.session.id])
        let daemon = try #require(fixture.runner.calls.first?.arguments.dropFirst().first)
        #expect(fixture.runner.calls.last?.arguments == ["kill", daemon, "--force"])
    }

    @Test func aHostedZmxNewNeverCreatesOnTheHeadlessOrigin() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = await fixture.actions.respond(to: HeadlessRequests.request(.zmxNew) { $0.host = "elsewhere" })

        #expect(!response.ok)
        #expect(response.error?.contains("zmx.new") == true)
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test(arguments: [(PresentationMode.presenter, true), (.mirror, true), (.presenter, false), (.mirror, false)])
    func aSeenFrameClearsUnseenAndOnlyAutoResetStatus(mode: PresentationMode, autoReset: Bool) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let workspace = try #require(fixture.store.workspaces.first)
        let other = try #require(fixture.store.addSession(toWorkspace: workspace.id, cwd: fixture.directory.path))
        other.unseenCount = 9
        fixture.store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: other.id)
        let viewer = try HeadlessAskTests.Sink(fixture, mode: mode)
        if mode == .presenter { viewer.send(.presenterAcquire) }
        fixture.session.unseenCount = 4
        #expect(try await fixture.dispatch(.sessionStatus) { $0.status = "blocked"; $0.autoReset = autoReset }.ok)
        #expect(fixture.session.agentIndicator.status == .blocked)
        viewer.send(.seen)
        #expect(fixture.session.unseenCount == 0)
        #expect(try await fixture.node().unseen == nil)
        #expect(fixture.session.agentIndicator.status == (autoReset ? .idle : .blocked))
        #expect(other.unseenCount == 9)
        #expect(other.agentIndicator.status == .completed)
        if autoReset {
            #expect(fixture.store.presentationSnapshot(forSession: fixture.session.id).status == nil)
            #expect(viewer.bodies.last == .status(nil))
        }
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func sessionSeenClearsTheCountButLeavesTheStatus() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.session.unseenCount = 4
        #expect(try await fixture.dispatch(.sessionStatus) { $0.status = "completed"; $0.autoReset = true }.ok)
        #expect(try await fixture.dispatch(.sessionSeen).ok)
        #expect(fixture.session.unseenCount == 0)
        #expect(fixture.session.agentIndicator.status == .completed)
        #expect(fixture.runner.calls.isEmpty)
    }

}
