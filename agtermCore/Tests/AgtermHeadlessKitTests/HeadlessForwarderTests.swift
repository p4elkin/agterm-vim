import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
@Suite(.serialized)
struct HeadlessForwarderTests {
    final class Presenter: PresentationSink {
        var bodies: [PresentationFrame.Body] = []
        private let hub: PresentationHub
        private var subscriber: PresentationHub.SubscriberID?
        private var generation = 0

        init(_ hub: PresentationHub, session: UUID, kinds: [String] = ["forward"]) throws {
            self.hub = hub
            subscriber = try hub.subscribe(session: session, hello: PresentationHello(version: 1, kinds: kinds, mode: .presenter),
                                           sink: self) { PresentationSnapshot(status: nil, hud: nil) }
            send(.presenterAcquire)
        }

        func offer(_ frame: PresentationFrame) -> Bool {
            generation = frame.gen
            bodies.append(frame.body)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        func send(_ body: PresentationFrame.Body) {
            guard let subscriber else { return }
            hub.receive(PresentationFrame(gen: generation, rev: 0, body: body), from: subscriber)
        }

        func disconnect() {
            if let subscriber { hub.unsubscribe(subscriber) }
            subscriber = nil
        }

        var forwards: [PresentationForward] {
            bodies.compactMap { if case .controlForward(let forward) = $0 { forward } else { nil } }
        }

        func reply(_ response: ControlResponse, to index: Int = 0) {
            send(.controlForwarded(PresentationForwarded(id: forwards[index].id, response: response)))
        }
    }

    private func respond(_ fixture: HeadlessActionFixture, _ request: ControlRequest) -> Task<ControlResponse, Never> {
        Task { await fixture.actions.respond(to: request) }
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func anAllowlistedRequestReachesThePresenterWithTheFullIDAndNoWindow() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let request = HeadlessRequests.request(.sessionFlag, target: fixture.session.id.uuidString) {
            $0.mode = "on"; $0.window = "somewhere"
        }

        let answer = respond(fixture, request)
        await settle { !presenter.forwards.isEmpty }
        let sent = try #require(presenter.forwards.first)
        #expect(sent.request.target == fixture.session.id.uuidString)
        #expect(sent.request.args?.window == nil)
        presenter.reply(ControlResponse(ok: true, result: ControlResult(id: fixture.session.id.uuidString)))

        #expect(await answer.value == ControlResponse(ok: true, result: ControlResult(id: fixture.session.id.uuidString)))
    }

    @Test func anAttachBesideReachesTheRowsPresenterWithTheSessionToAttach() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let request = HeadlessRequests.request(.zmxAttach, target: fixture.session.id.uuidString) {
            $0.host = "p4linux"; $0.attach = "new-session"
        }

        let answer = respond(fixture, request)
        await settle { !presenter.forwards.isEmpty }
        let sent = try #require(presenter.forwards.first)
        #expect(sent.request.cmd == .zmxAttach)
        #expect(sent.request.target == fixture.session.id.uuidString)
        #expect(sent.request.args?.attach == "new-session")
        presenter.reply(ControlResponse(ok: true, result: ControlResult(id: "new-session")))

        #expect(await answer.value == ControlResponse(ok: true, result: ControlResult(id: "new-session")))
    }

    @Test(arguments: [nil, "not-a-session", "00000000-0000-0000-0000-00000000dead"])
    func aTargetThatIsNotAServerSessionIsRefused(_ target: String?) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)

        let response = await fixture.actions.respond(to: ControlRequest(cmd: .sessionFlag, target: target))

        #expect(response.error == "session.flag cannot be forwarded: it needs --target naming a session on this origin")
        #expect(presenter.forwards.isEmpty)
    }

    @Test func noPresenterAndAPresenterWithoutForwardAreRefused() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let request = HeadlessRequests.request(.sessionFlag, target: fixture.session.id.uuidString)

        #expect(await fixture.actions.respond(to: request).error == "session.flag cannot be forwarded: no Mac is presenting this session")
        let old = try Presenter(fixture.headless.hub, session: fixture.session.id, kinds: ["status"])
        #expect(await fixture.actions.respond(to: request).error
            == "session.flag cannot be forwarded: the presenting Mac does not support forwarding")
        #expect(old.forwards.isEmpty)
    }

    @Test func aRequestOverTheFrameLimitIsRefusedBeforeSending() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let items = (0..<20_000).map { ControlPickItem(id: "item-\($0)", label: String(repeating: "x", count: 20)) }
        let request = HeadlessRequests.request(.pickOpen, target: fixture.session.id.uuidString) { $0.items = items }

        let response = await fixture.actions.respond(to: request)

        #expect(response.error == "pick.open cannot be forwarded: the request is larger than the presentation frame limit")
        #expect(presenter.forwards.isEmpty)
    }

    @Test func noReplyWithinTheDeadlineFails() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        _ = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let forwarder = HeadlessForwarder(hub: fixture.headless.hub, deadline: 0.05)

        let response = await forwarder.forward(ControlRequest(cmd: .sessionFlag, target: fixture.session.id.uuidString),
                                               session: fixture.session.id)

        #expect(response.error == "the presenting Mac left")
    }

    @Test func thePresenterLeavingFailsWhatWaitsOnIt() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)

        let answer = respond(fixture, HeadlessRequests.request(.sessionFlag, target: fixture.session.id.uuidString))
        await settle { !presenter.forwards.isEmpty }
        presenter.disconnect()

        #expect(await answer.value.error == "the presenting Mac left")
    }

    @Test func pickPollsGoToTheMacThatOpenedItAndEndOnceItLeft() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let open = respond(fixture, HeadlessRequests.request(.pickOpen, target: fixture.session.id.uuidString) {
            $0.items = [ControlPickItem(id: "a", label: "A")]
        })
        await settle { presenter.forwards.count == 1 }
        presenter.reply(ControlResponse(ok: true, result: ControlResult(id: "pick-1")))
        #expect(await open.value.result?.id == "pick-1")

        let poll = respond(fixture, ControlRequest(cmd: .pickResult, target: "pick-1"))
        await settle { presenter.forwards.count == 2 }
        #expect(presenter.forwards[1].request.target == "pick-1")
        presenter.reply(ControlResponse(ok: true, result: ControlResult(pick: ControlPickResult(result: .pending))), to: 1)
        #expect(await poll.value.result?.pick?.result == .pending)

        presenter.disconnect()
        let after = await fixture.actions.respond(to: ControlRequest(cmd: .pickCancel, target: "pick-1"))
        #expect(after.result?.pick?.result == .cancelled)
    }

    @Test func pagePollsGoToTheMacThatOpenedItAndAnswerDismissedOnceItLeft() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let open = respond(fixture, HeadlessRequests.request(.sessionOverlayOpen, target: fixture.session.id.uuidString) {
            $0.url = "http://example.com"
        })
        await settle { presenter.forwards.count == 1 }
        var opened = ControlResult(id: fixture.session.id.uuidString)
        opened.pageID = "page-1"
        presenter.reply(ControlResponse(ok: true, result: opened))
        #expect(await open.value.result?.pageID == "page-1")

        let poll = respond(fixture, ControlRequest(cmd: .sessionOverlayResult, args: ControlArgs(page: "page-1")))
        await settle { presenter.forwards.count == 2 }
        #expect(presenter.forwards[1].request.args?.page == "page-1")
        presenter.reply(ControlResponse(ok: true), to: 1)
        _ = await poll.value

        presenter.disconnect()
        let after = await fixture.actions.respond(to: ControlRequest(cmd: .sessionOverlayResult, args: ControlArgs(page: "page-1")))
        #expect(after.result?.pageOutcome == ControlHtmlPageOutcome(pageID: "page-1", outcome: .dismissed))
    }

    @Test func aPollForAPickNoMacOpenedIsUnknown() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)

        let response = await fixture.actions.respond(to: ControlRequest(cmd: .pickResult, target: "nope"))

        #expect(response.error == "unknown pick: nope")
        #expect(presenter.forwards.isEmpty)
    }

    @Test func closingTheSessionForgetsItsPicks() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let open = respond(fixture, HeadlessRequests.request(.pickOpen, target: fixture.session.id.uuidString) {
            $0.items = [ControlPickItem(id: "a", label: "A")]
        })
        await settle { presenter.forwards.count == 1 }
        presenter.reply(ControlResponse(ok: true, result: ControlResult(id: "pick-1")))
        _ = await open.value

        fixture.headless.closeSession(fixture.session, in: fixture.store)

        #expect(await fixture.actions.respond(to: ControlRequest(cmd: .pickResult, target: "pick-1")).error == "unknown pick: pick-1")
    }

    private func openPick(_ fixture: HeadlessActionFixture, _ presenter: Presenter, _ id: String) async {
        let open = respond(fixture, HeadlessRequests.request(.pickOpen, target: fixture.session.id.uuidString) {
            $0.items = [ControlPickItem(id: "a", label: "A")]
        })
        let sent = presenter.forwards.count
        await settle { presenter.forwards.count == sent + 1 }
        presenter.reply(ControlResponse(ok: true, result: ControlResult(id: id)), to: sent)
        _ = await open.value
    }

    private func answer(_ fixture: HeadlessActionFixture, _ presenter: Presenter, _ request: ControlRequest,
                        with response: ControlResponse) async -> ControlResponse {
        let poll = respond(fixture, request)
        let sent = presenter.forwards.count
        await settle { presenter.forwards.count == sent + 1 }
        presenter.reply(response, to: sent)
        return await poll.value
    }

    @Test func finishedPicksBeyondTheRetainedLimitAreForgottenOldestFirst() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.headless.forwarder = HeadlessForwarder(hub: fixture.headless.hub, retainedLimit: 2)
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        let picked = ControlResponse(ok: true, result: ControlResult(pick: ControlPickResult(result: .picked, id: "a")))
        for index in 0..<3 {
            await openPick(fixture, presenter, "pick-\(index)")
            _ = await answer(fixture, presenter, ControlRequest(cmd: .pickResult, target: "pick-\(index)"), with: picked)
        }

        #expect(await fixture.actions.respond(to: ControlRequest(cmd: .pickResult, target: "pick-0")).error == "unknown pick: pick-0")
        #expect(await answer(fixture, presenter, ControlRequest(cmd: .pickResult, target: "pick-2"), with: picked) == picked)
    }

    @Test func aLivePickIsNeverForgottenAndAStaleOneKeepsItsFinalAnswerWithinTheLimit() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.headless.forwarder = HeadlessForwarder(hub: fixture.headless.hub, retainedLimit: 2)
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        for index in 0..<3 { await openPick(fixture, presenter, "pick-\(index)") }
        let pending = ControlResponse(ok: true, result: ControlResult(pick: ControlPickResult(result: .pending)))
        #expect(await answer(fixture, presenter, ControlRequest(cmd: .pickResult, target: "pick-0"), with: pending) == pending)

        presenter.disconnect()

        #expect(await fixture.actions.respond(to: ControlRequest(cmd: .pickResult, target: "pick-0")).error == "unknown pick: pick-0")
        #expect(await fixture.actions.respond(to: ControlRequest(cmd: .pickResult, target: "pick-2")).result?.pick?.result == .cancelled)
    }

    @Test func aFinishedPageBeyondTheLimitIsNoSuchPage() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        fixture.headless.forwarder = HeadlessForwarder(hub: fixture.headless.hub, retainedLimit: 1)
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)
        for index in 0..<2 {
            let open = respond(fixture, HeadlessRequests.request(.sessionOverlayOpen, target: fixture.session.id.uuidString) {
                $0.url = "https://example.com"
            })
            let sent = presenter.forwards.count
            await settle { presenter.forwards.count == sent + 1 }
            var opened = ControlResult(id: fixture.session.id.uuidString)
            opened.pageID = "page-\(index)"
            presenter.reply(ControlResponse(ok: true, result: opened), to: sent)
            _ = await open.value
            let done = ControlResponse(ok: true, result: ControlResult(pageOutcome: ControlHtmlPageOutcome(pageID: "page-\(index)", outcome: .dismissed)))
            _ = await answer(fixture, presenter, ControlRequest(cmd: .sessionOverlayResult, args: ControlArgs(page: "page-\(index)")), with: done)
        }

        let gone = await fixture.actions.respond(to: ControlRequest(cmd: .sessionOverlayResult, args: ControlArgs(page: "page-0")))
        #expect(gone.error == OverlayHtmlError.unknownPage)
    }

    @Test func aPageCloseWithNoJobIsForwardedThroughRespond() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Presenter(fixture.headless.hub, session: fixture.session.id)

        let close = respond(fixture, HeadlessRequests.request(.sessionOverlayClose, target: fixture.session.id.uuidString))
        await settle { !presenter.forwards.isEmpty }
        presenter.reply(ControlResponse(ok: true))

        #expect(await close.value.ok)
        #expect(presenter.forwards.map(\.request.cmd) == [.sessionOverlayClose])
    }
}
