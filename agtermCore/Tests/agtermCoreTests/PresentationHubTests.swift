import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PresentationHubTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []
        var closed: PresentationHub.CloseReason?
        var capacity = Int.max

        func offer(_ frame: PresentationFrame) -> Bool {
            guard frames.count < capacity else { return false }
            frames.append(frame)
            return true
        }

        func close(_ reason: PresentationHub.CloseReason) { closed = reason }

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_789_000_000)
    }

    static let hello = PresentationHello(version: 1, kinds: ["status", "hud", "notify"], mode: .mirror)
    static let session = UUID()
    static let blocked = PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: nil,
                                            changedAt: nil)
    static let empty = PresentationSnapshot(status: nil, hud: nil)

    let clock = Clock()

    func makeHub() -> PresentationHub {
        let clock = clock
        return PresentationHub(staleTimeout: 30, now: { clock.now })
    }

    @Test func subscribeAnswersHelloThenTheSnapshotBeforeAnyDelta() throws {
        let hub = makeHub()
        let sink = Sink()
        let snapshot = PresentationSnapshot(status: Self.blocked, hud: nil)

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { snapshot }
        hub.publish(.status(nil), session: Self.session)

        #expect(sink.bodies == [.hello(Self.hello), .snapshot(snapshot), .status(nil)])
    }

    @Test func aChangeMadeWhileTheSnapshotIsTakenLandsAfterIt() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) {
            hub.publish(.status(Self.blocked), session: Self.session)
            return Self.empty
        }

        #expect(sink.bodies == [.hello(Self.hello), .snapshot(Self.empty), .status(Self.blocked)])
    }

    @Test func revisionsAreMonotonicWithinOneGeneration() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }
        hub.publish(.status(Self.blocked), session: Self.session)
        hub.publish(.hud(nil), session: Self.session)

        #expect(Set(sink.frames.map(\.gen)).count == 1)
        #expect(sink.frames.map(\.rev) == [0, 1, 2, 3])
    }

    @Test func aSecondSubscriberToOneSessionGetsItsOwnGeneration() throws {
        let hub = makeHub()
        let first = Sink()
        let second = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: first) { Self.empty }
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: second) { Self.empty }
        hub.publish(.status(Self.blocked), session: Self.session)

        #expect(first.frames[0].gen != second.frames[0].gen)
        #expect(first.bodies.last == .status(Self.blocked))
        #expect(second.bodies.last == .status(Self.blocked))
        #expect(hub.subscriberCount(session: Self.session) == 2)
    }

    @Test func aPublishForAnotherSessionReachesNobody() throws {
        let hub = makeHub()
        let sink = Sink()

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }
        hub.publish(.status(Self.blocked), session: UUID())

        #expect(sink.frames.count == 2)
    }

    @Test func aFullQueueDisconnectsThatSubscriberOnly() throws {
        let hub = makeHub()
        let stalled = Sink()
        let healthy = Sink()
        stalled.capacity = 2

        try hub.subscribe(session: Self.session, hello: Self.hello, sink: stalled) { Self.empty }
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: healthy) { Self.empty }
        hub.publish(.status(Self.blocked), session: Self.session)

        #expect(stalled.closed == .stalled)
        #expect(healthy.closed == nil)
        #expect(healthy.bodies.last == .status(Self.blocked))
        #expect(hub.subscriberCount(session: Self.session) == 1)
    }

    @Test func unsubscribeReleasesTheSubscriber() throws {
        let hub = makeHub()
        let sink = Sink()

        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }
        hub.unsubscribe(id)
        hub.publish(.status(Self.blocked), session: Self.session)

        #expect(sink.frames.count == 2)
        #expect(sink.closed == nil)
        #expect(hub.subscriberCount(session: Self.session) == 0)
    }

    @Test(arguments: [false, true])
    func aNewSubscriberReceivesAReturnToThePreviousLayout(staleHeartbeat: Bool) throws {
        let hub = makeHub()
        let first = Sink()
        let primary = UUID()
        let initial = PresentationLayout(panes: [primary], primary: primary, shown: false)
        let changed = PresentationLayout(panes: [primary, UUID()], primary: primary, axis: "vertical", shown: true)
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: first) {
            PresentationSnapshot(status: nil, hud: nil, layout: initial)
        }
        if staleHeartbeat {
            clock.now += 31
            hub.heartbeat()
            #expect(first.closed == .stale)
        } else {
            hub.unsubscribe(id)
        }
        #expect(hub.subscriberCount(session: Self.session) == 0)
        hub.publishLayout(changed, session: Self.session)
        let next = Sink()
        let snapshot = PresentationSnapshot(status: nil, hud: nil, layout: changed)
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: next) { snapshot }
        #expect(next.bodies.last == .snapshot(snapshot))

        hub.publishLayout(initial, session: Self.session)

        #expect(next.bodies.last == .layout(initial))
        #expect(next.frames.count == 3)
    }

    @Test func theAnswerAdvertisesOnlyKindsBothSidesSpeak() throws {
        let hub = makeHub()
        let sink = Sink()
        let hello = PresentationHello(version: 1, kinds: ["notify", "overlay.request", "status"], mode: .presenter)

        try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.empty }

        #expect(sink.bodies.first == .hello(PresentationHello(version: 1, kinds: ["status", "notify"],
                                                              mode: .presenter)))
    }

    @Test func aPeerWithNoUsableVersionIsRefused() {
        let hub = makeHub()
        let sink = Sink()
        let hello = PresentationHello(version: 0, kinds: [], mode: .mirror)

        #expect(throws: PresentationHub.SubscribeError.unsupportedVersion(0)) {
            try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.empty }
        }
        #expect(sink.frames.isEmpty)
    }

    @Test func aHeartbeatPingsAndAnAckKeepsTheSubscriberAlive() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        clock.now += 20
        hub.heartbeat()
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .ack), from: id)
        clock.now += 20
        hub.heartbeat()

        #expect(sink.bodies.filter { $0 == .ping }.count == 2)
        #expect(sink.closed == nil)
    }

    @Test func aMissedAckPastTheStaleTimeoutClosesTheSubscriber() throws {
        let hub = makeHub()
        let sink = Sink()
        try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        clock.now += 20
        hub.heartbeat()
        clock.now += 20
        hub.heartbeat()

        #expect(sink.closed == .stale)
        #expect(hub.subscriberCount(session: Self.session) == 0)
    }

    @Test func aPingFromTheViewerIsAnswered() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .ping), from: id)

        #expect(sink.bodies.last == .ack)
    }

    @Test func aFrameFromAnotherGenerationIsIgnored() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session, hello: Self.hello, sink: sink) { Self.empty }

        hub.receive(PresentationFrame(gen: sink.frames[0].gen + 1, rev: 0, body: .ping), from: id)

        #expect(sink.frames.count == 2)
    }

    @Test func aFirstAcquireNotifiesChangedOnceAndNeverWillChange() throws {
        let hub = makeHub()
        let sink = Sink()
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.empty }
        var changed: [UUID] = []
        var willChange: [UUID] = []
        hub.onPresenterChanged = { changed.append($0) }
        hub.onPresenterWillChange = { willChange.append($0) }

        for _ in 0..<2 {
            hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        }

        #expect(changed == [Self.session])
        #expect(willChange.isEmpty)
    }

    @Test func aDisconnectHandsOffToTheEarliestPresenterModeViewer() throws {
        let hub = makeHub()
        let first = Sink()
        let earliest = Sink()
        let later = Sink()
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: Self.session, hello: hello, sink: first) { Self.empty }
        try hub.subscribe(session: Self.session, hello: hello, sink: earliest) { Self.empty }
        try hub.subscribe(session: Self.session, hello: hello, sink: later) { Self.empty }
        hub.receive(PresentationFrame(gen: first.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        var events: [String] = []
        hub.onPresenterWillChange = { session in
            #expect(session == Self.session)
            #expect(hub.hasPresenter(session: session))
            events.append("will")
        }
        hub.onPresenterChanged = { session in
            #expect(session == Self.session)
            #expect(earliest.bodies.last == .presenterGranted)
            events.append("changed")
        }
        hub.onPresenterLost = { _ in events.append("lost") }

        hub.unsubscribe(id)

        #expect(events == ["will", "changed"])
        #expect(hub.hasPresenter(session: Self.session))
        #expect(earliest.bodies.last == .presenterGranted)
        #expect(later.frames.count == 2)
    }

    @Test(arguments: [false, true])
    func aReleaseWithNoEligibleViewerNotifiesWillChangeThenLost(withMirror: Bool) throws {
        let hub = makeHub()
        let sink = Sink()
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: Self.session, hello: hello, sink: sink) { Self.empty }
        let mirror = Sink()
        if withMirror {
            try hub.subscribe(session: Self.session, hello: Self.hello, sink: mirror) { Self.empty }
        }
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        var events: [String] = []
        hub.onPresenterWillChange = { _ in events.append("will") }
        hub.onPresenterChanged = { _ in events.append("changed") }
        hub.onPresenterLost = { _ in events.append("lost") }

        hub.unsubscribe(id)

        #expect(events == ["will", "lost"])
        #expect(!hub.hasPresenter(session: Self.session))
        #expect(!mirror.bodies.contains(.presenterGranted))
    }

    @Test func aRefusedAcquireFiresNoPresenterCallback() throws {
        let hub = makeHub()
        let first = Sink()
        let second = Sink()
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: Self.session, hello: hello, sink: first) { Self.empty }
        let other = try hub.subscribe(session: Self.session, hello: hello, sink: second) { Self.empty }
        hub.receive(PresentationFrame(gen: first.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        var events: [String] = []
        hub.onPresenterWillChange = { _ in events.append("will") }
        hub.onPresenterChanged = { _ in events.append("changed") }
        hub.onPresenterLost = { _ in events.append("lost") }

        hub.receive(PresentationFrame(gen: second.frames[0].gen, rev: 0, body: .presenterAcquire), from: other)

        #expect(second.bodies.last == .presenterRefused)
        #expect(events.isEmpty)
    }

    @Test func aTakeDismissesThroughTheOldHolderBeforeGrantingTheNewOne() throws {
        let hub = makeHub()
        let first = Sink(), second = Sink()
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let firstID = try hub.subscribe(session: Self.session, hello: hello, sink: first) { Self.empty }
        let secondID = try hub.subscribe(session: Self.session, hello: hello, sink: second) { Self.empty }
        hub.receive(PresentationFrame(gen: first.frames[0].gen, rev: 0, body: .presenterAcquire), from: firstID)
        let owner = hub.presenterGeneration(session: Self.session)
        var callbacks: [String] = []
        hub.onPresenterWillChange = { session in
            #expect(session == Self.session)
            #expect(hub.presenterGeneration(session: session) == owner)
            #expect(hub.sendToPresenter(.context("old holder"), session: session))
            #expect(first.bodies.last == .context("old holder"))
            callbacks.append("will")
        }
        hub.onPresenterChanged = { session in
            #expect(session == Self.session)
            #expect(first.bodies.last == .presenterRefused)
            #expect(second.bodies.last == .presenterGranted)
            #expect(hub.presenterGeneration(session: session) == owner + 1)
            #expect(hub.sendToPresenter(.context("new holder"), session: session))
            #expect(second.bodies.last == .context("new holder"))
            callbacks.append("changed")
        }
        hub.onPresenterLost = { _ in Issue.record("take must keep a presenter") }
        let take = PresentationFrame(gen: second.frames[0].gen, rev: 0, body: .presenterTake)
        hub.receive(take, from: secondID)
        #expect(callbacks == ["will", "changed"])
        hub.receive(take, from: secondID)
        #expect(callbacks == ["will", "changed"])
        #expect(hub.presenterGeneration(session: Self.session) == owner + 1)
        #expect(second.bodies.last == .presenterGranted)
        hub.receive(PresentationFrame(gen: first.frames[0].gen + 100, rev: 0, body: .presenterTake), from: firstID)
        #expect(hub.presenterGeneration(session: Self.session) == owner + 1)
    }

    @Test func aTakeOnAVacantSessionGrantsWithoutWillChange() throws {
        let hub = makeHub()
        let sink = Sink()
        let id = try hub.subscribe(session: Self.session,
            hello: PresentationHello(version: 1, kinds: [], mode: .presenter), sink: sink) { Self.empty }
        var changes = 0
        hub.onPresenterWillChange = { _ in Issue.record("no previous holder") }
        hub.onPresenterChanged = { _ in changes += 1 }
        hub.receive(PresentationFrame(gen: sink.frames[0].gen, rev: 0, body: .presenterTake), from: id)
        #expect(sink.bodies.last == .presenterGranted)
        #expect(changes == 1)
        #expect(hub.presenterGeneration(session: Self.session) == 1)
    }

    @Test(arguments: [false, true])
    func aStalledOldViewerDoesNotDuplicateTheNewGrantCallback(dismissalStalls: Bool) throws {
        let hub = makeHub()
        let first = Sink(), next = Sink()
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let firstID = try hub.subscribe(session: Self.session, hello: hello, sink: first) { Self.empty }
        let nextID = try hub.subscribe(session: Self.session, hello: hello, sink: next) { Self.empty }
        hub.receive(PresentationFrame(gen: first.frames[0].gen, rev: 0, body: .presenterAcquire), from: firstID)
        first.capacity = first.frames.count
        var changed = 0
        hub.onPresenterWillChange = { session in
            if dismissalStalls { hub.sendToPresenter(.context("dismiss"), session: session) }
        }
        hub.onPresenterChanged = { _ in changed += 1 }
        hub.receive(PresentationFrame(gen: next.frames[0].gen, rev: 0, body: .presenterTake), from: nextID)
        #expect(first.closed == .stalled)
        #expect(next.bodies.last == .presenterGranted)
        #expect(changed == 1)
        #expect(hub.subscriberCount(session: Self.session) == 1)
    }

    @Test func aStalledTakerReturnsTheRoleToASurvivingViewer() throws {
        let hub = makeHub()
        let first = Sink(), next = Sink()
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let firstID = try hub.subscribe(session: Self.session, hello: hello, sink: first) { Self.empty }
        let nextID = try hub.subscribe(session: Self.session, hello: hello, sink: next) { Self.empty }
        hub.receive(PresentationFrame(gen: first.frames[0].gen, rev: 0, body: .presenterAcquire), from: firstID)
        next.capacity = next.frames.count
        var changed = 0
        hub.onPresenterChanged = { _ in changed += 1 }
        hub.receive(PresentationFrame(gen: next.frames[0].gen, rev: 0, body: .presenterTake), from: nextID)
        #expect(next.closed == .stalled)
        #expect(first.bodies.suffix(2) == [.presenterRefused, .presenterGranted])
        #expect(changed == 1)
        #expect(hub.hasPresenter(session: Self.session))
    }

    @Test(arguments: [PresentationMode.presenter, .mirror])
    func seenRoutesFromAnyCurrentViewerToItsOwnSession(mode: PresentationMode) throws {
        let hub = makeHub()
        let sink = Sink()
        let session = UUID()
        let id = try hub.subscribe(session: session,
            hello: PresentationHello(version: 1, kinds: [], mode: mode), sink: sink) { Self.empty }
        let generation = try #require(sink.frames.first?.gen)
        if mode == .presenter {
            hub.receive(PresentationFrame(gen: generation, rev: 0, body: .presenterAcquire), from: id)
        }
        var seen: [UUID] = []
        hub.onSeen = { seen.append($0) }
        hub.onPresenterFrame = { _, _ in Issue.record("seen is separate from presenter work") }
        hub.receive(PresentationFrame(gen: generation + 1, rev: 0, body: .seen), from: id)
        #expect(seen.isEmpty)
        let count = sink.frames.count
        hub.receive(PresentationFrame(gen: generation, rev: 0, body: .seen), from: id)
        #expect(seen == [session])
        #expect(sink.frames.count == count)
        #expect(hub.hasPresenter(session: session) == (mode == .presenter))
        hub.unsubscribe(id)
        hub.receive(PresentationFrame(gen: generation, rev: 0, body: .seen), from: id)
        #expect(seen == [session])
    }

}
