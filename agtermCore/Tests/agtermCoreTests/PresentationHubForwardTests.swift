import Foundation
import Testing
@testable import agtermCore

extension PresentationHubTests {
    private func presenter(_ hub: PresentationHub, kinds: [String], sink: Sink) throws -> PresentationHub.SubscriberID {
        let hello = PresentationHello(version: 1, kinds: kinds, mode: .presenter)
        let id = try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.empty }
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return id
    }

    @Test func onlyAPresenterThatListedForwardSupportsIt() throws {
        let hub = makeHub()
        #expect(!hub.presenterSupports("forward", session: Self.session))
        _ = try presenter(hub, kinds: ["status"], sink: Sink())
        #expect(!hub.presenterSupports("forward", session: Self.session))

        let other = makeHub()
        _ = try presenter(other, kinds: ["status", "forward"], sink: Sink())
        #expect(other.presenterSupports("forward", session: Self.session))
    }

    @Test func aMirrorThatListedForwardDoesNotMakeThePresenterSupportIt() throws {
        let hub = makeHub()
        _ = try presenter(hub, kinds: [], sink: Sink())
        let mirror = PresentationHello(version: 1, kinds: ["forward"], mode: .mirror)
        try hub.subscribe(session: Self.session, hello: mirror, sink: Sink()) { Self.empty }

        #expect(!hub.presenterSupports("forward", session: Self.session))
    }

    @Test func aForwardReplyReachesTheOriginOnlyFromThePresenter() throws {
        let hub = makeHub()
        let presenting = Sink()
        let id = try presenter(hub, kinds: ["forward"], sink: presenting)
        let mirrorSink = Sink()
        let mirror = try hub.subscribe(session: Self.session, hello: PresentationHello(version: 1, kinds: ["forward"], mode: .mirror),
                                       sink: mirrorSink) { Self.empty }
        var received: [PresentationFrame.Body] = []
        hub.onPresenterFrame = { session, body in
            #expect(session == Self.session)
            received.append(body)
        }
        let reply = PresentationFrame.Body.controlForwarded(PresentationForwarded(id: "r1", response: ControlResponse(ok: true)))

        hub.receive(PresentationFrame(gen: mirrorSink.frames[0].gen, rev: 0, body: reply), from: mirror)
        hub.receive(PresentationFrame(gen: presenting.frames[0].gen, rev: 0, body: reply), from: id)

        #expect(received == [reply])
    }
}
