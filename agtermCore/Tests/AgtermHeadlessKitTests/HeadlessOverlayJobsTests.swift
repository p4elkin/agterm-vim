import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
@Suite(.serialized)
struct HeadlessOverlayJobsTests {
    typealias Presenter = HeadlessForwarderTests.Presenter

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func open(_ fixture: HeadlessActionFixture, _ command: String = "revdiff",
                      _ edit: (inout ControlArgs) -> Void = { _ in }) async throws -> ControlResponse {
        try await fixture.dispatch(.sessionOverlayOpen) { $0.command = command; edit(&$0) }
    }

    private func result(_ fixture: HeadlessActionFixture) async -> ControlResponse {
        await fixture.actions.respond(to: HeadlessRequests.request(.sessionOverlayResult, target: fixture.session.id.uuidString))
    }

    private func requests(_ presenter: Presenter) -> [PresentationOverlay] {
        presenter.bodies.compactMap { if case .overlayRequest(let overlay) = $0 { overlay } else { nil } }
    }

    private func closes(_ presenter: Presenter) -> [String] {
        presenter.bodies.compactMap { if case .overlayClose(let change) = $0 { change.job } else { nil } }
    }

    private func job(_ fixture: HeadlessActionFixture, _ presenter: Presenter) throws -> OverlayJob {
        let id = try #require(requests(presenter).last?.job)
        return try #require(fixture.headless.overlayJobs.job(id))
    }

    @Test func anOpenWithAPresenterAndNoLeadBooksAJobAndAsksThePresenter() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)

        let response = try await open(fixture)

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: fixture.session.id.uuidString)))
        let job = try job(fixture, presenter)
        #expect(job.context.command == "revdiff")
        #expect(job.session == fixture.session.id)
        #expect(fixture.session.remoteOverlays.slot(nil)?.job == job.id)
    }

    @Test func theLaunchContextCarriesTheSessionEnvironmentWithNoPane() async throws {
        let fixture = try HeadlessActionFixture(shellLookup: { "/usr/bin/zsh" })
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)

        _ = try await open(fixture)

        let environment = try job(fixture, presenter).context.environment
        #expect(environment["AGTERM_SESSION_ID"] == fixture.session.id.uuidString)
        #expect(environment["AGTERM_PANE"] == nil)
        #expect(environment["AGTERM_STATE_DIR"] == fixture.headless.config.stateDirectory)
        #expect(environment["SHELL"] == "/usr/bin/zsh")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment[OverlayCapture.cmdEnvKey] == "revdiff")
    }

    @Test func theCwdIsTheCallersAbsolutePathElseTheSessionsAndARelativeOneIsRefused() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)

        _ = try await open(fixture)
        #expect(try job(fixture, presenter).context.cwd == fixture.session.effectiveCwd)
        _ = try await fixture.dispatch(.sessionOverlayClose)

        _ = try await open(fixture) { $0.cwd = "/tmp" }
        #expect(try job(fixture, presenter).context.cwd == "/tmp")
        _ = try await fixture.dispatch(.sessionOverlayClose)

        let relative = try await open(fixture) { $0.cwd = "src" }
        #expect(relative.error == "overlay --cwd must be an absolute path on this origin")
    }

    @Test func noPresenterIsRefusedAtOnce() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }

        let response = try await open(fixture)

        #expect(response.error == "session.overlay.open cannot run a program: no Mac is presenting this session")
        #expect(fixture.session.remoteOverlays.slots.isEmpty)
    }

    @Test func theServerAnswersResultAndSendsCloseAndResize() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)
        let job = try job(fixture, presenter)

        #expect(await result(fixture).error == OverlayResultError.stillRunning)
        #expect(try await fixture.dispatch(.sessionOverlayResize) { $0.sizePercent = 60 }.ok)
        #expect(presenter.bodies.contains(.overlayResize(PresentationOverlayChange(job: job.id, sizePercent: 60))))
        var cancelled = false
        _ = fixture.headless.overlayJobs.claim(job.id) { cancelled = true }
        #expect(try await fixture.dispatch(.sessionOverlayClose).ok)
        #expect(closes(presenter) == [job.id])
        #expect(cancelled)
        #expect(presenter.forwards.isEmpty)

        fixture.headless.overlayJobs.finish(job.id, .exited(3))
        #expect(await result(fixture) == ControlResponse(ok: true, result: ControlResult(id: fixture.session.id.uuidString, exitCode: 3)))
    }

    @Test func aPresenterRejectionEndsTheJobLaunchFailed() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)

        presenter.send(.overlayRejected(PresentationOverlayChange(job: try job(fixture, presenter).id)))

        #expect(await result(fixture).error == OverlayResultError.ended("launch-failed"))
        #expect(fixture.session.remoteOverlays.slot(nil) == nil)
    }

    @Test func noClaimWithinTheLaunchWindowFailsTheLaunchAndFreesTheSlot() async throws {
        let clock = Clock()
        let fixture = try HeadlessActionFixture(overlayClock: { clock.now })
        defer { fixture.cleanUp() }
        _ = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)

        clock.now += OverlayJobs.launchWindow
        fixture.headless.overlayJobs.expire()

        #expect(await result(fixture).error == OverlayResultError.ended("launch-failed"))
        #expect(fixture.session.remoteOverlays.slot(nil) == nil)
    }

    @Test func losingThePresenterBeforeTheClaimCancelsTheJob() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)

        presenter.disconnect()

        #expect(await result(fixture).error == OverlayResultError.ended("canceled"))
    }

    @Test func aNewPresenterClosesTheOldOnesSlot() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let old = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)
        let job = try job(fixture, old)

        let next = try Presenter(fixture.headless.hub, session: fixture.session.id)
        next.send(.presenterTake)

        #expect(closes(old) == [job.id])
        #expect(await result(fixture).error == OverlayResultError.ended("canceled"))
    }

    // MARK: the claim and the job stream

    private func claim(_ fixture: HeadlessActionFixture, _ job: String) async -> ControlResponse? {
        await fixture.actions.serve(ControlRequest(cmd: .sessionOverlayJobRun, target: job), connection: -1)
    }

    private func booked(_ fixture: HeadlessActionFixture) async throws -> OverlayJob {
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)
        return try job(fixture, presenter)
    }

    @Test func aClaimTakesTheConnectionAndSendsTheContextFirst() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let job = try await booked(fixture)

        #expect(await claim(fixture, job.id) == nil)

        let helper = try #require(fixture.streams.jobs.first)
        #expect(helper.reply == ControlResponse(ok: true, result: ControlResult(id: job.id)))
        #expect(helper.frames == [.context(job.context)])
    }

    @Test func aSecondClaimAnUnknownJobAndAnExpiredOneAreRefused() async throws {
        let clock = Clock()
        let fixture = try HeadlessActionFixture(overlayClock: { clock.now })
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)
        let first = try job(fixture, presenter)
        _ = await claim(fixture, first.id)

        #expect(await claim(fixture, first.id)?.error == "job not claimable")
        #expect(await claim(fixture, UUID().uuidString)?.error == "job not claimable")

        fixture.headless.overlayJobs.finish(first.id, .exited(0))
        _ = try await open(fixture)
        let late = try job(fixture, presenter)
        clock.now += OverlayJobs.launchWindow
        #expect(await claim(fixture, late.id)?.error == "job not claimable")
        #expect(fixture.streams.jobs.count == 1)
    }

    @Test func aCancelBeforeTheAdoptionIsSentAfterTheContext() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let job = try await booked(fixture)
        #expect(fixture.headless.claimOverlayJob(job.id).ok)

        #expect(try await fixture.dispatch(.sessionOverlayClose).ok)
        fixture.headless.adoptJob(job.id, fd: -1, reply: ControlResponse(ok: true, result: ControlResult(id: job.id)))

        #expect(try #require(fixture.streams.jobs.first).frames == [.context(job.context), .cancel])
    }

    @Test func theReportedExitEndsTheJobWithItsStatus() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let job = try await booked(fixture)
        _ = await claim(fixture, job.id)
        let helper = try #require(fixture.streams.jobs.first)

        try helper.report(.started)
        try helper.report(.exited(5))

        #expect(await result(fixture) == ControlResponse(ok: true, result: ControlResult(id: fixture.session.id.uuidString, exitCode: 5)))
        #expect(fixture.session.remoteOverlays.slot(nil) == nil)
    }

    @Test func aReplyThatCannotBeWrittenLeavesNobodyToRunTheJob() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let job = try await booked(fixture)
        fixture.streams.acceptsJobs = false

        #expect(await claim(fixture, job.id) == nil)

        #expect(fixture.headless.overlayJobs.job(job.id)?.state == .finished(.unknown))
        #expect(await result(fixture).error == OverlayResultError.ended("unknown"))
    }

    @Test func aHelperThatLeavesWithoutAnOutcomeEndsTheJobUnknown() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let job = try await booked(fixture)
        _ = await claim(fixture, job.id)
        let helper = try #require(fixture.streams.jobs.first)
        try helper.report(.started)

        helper.onClose()

        #expect(fixture.headless.overlayJobs.job(job.id)?.state == .finished(.unknown))
    }

    @Test func aClaimedJobThatNeverStartsExpiresAndFreesTheSlot() async throws {
        let clock = Clock()
        let fixture = try HeadlessActionFixture(overlayClock: { clock.now })
        defer { fixture.cleanUp() }
        _ = try Presenter(fixture.headless.hub, session: fixture.session.id)
        _ = try await open(fixture)
        let job = try #require(fixture.session.remoteOverlays.slot(nil)?.job)
        _ = await claim(fixture, job)

        clock.now += OverlayJobs.startWindow
        fixture.headless.overlayJobs.expire()

        #expect(await result(fixture).error == OverlayResultError.ended("unknown"))
        #expect(fixture.session.remoteOverlays.slot(nil) == nil)
    }
}
