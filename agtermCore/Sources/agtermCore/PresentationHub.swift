import Foundation

/// PresentationSink is where the hub hands a subscriber's frames. The bounded queue and the socket live behind
/// it, off the main actor; the hub only learns whether a frame was taken.
@MainActor
public protocol PresentationSink: AnyObject {
    /// Returns false when the consumer's queue is full, which the hub treats as a stalled subscriber.
    func offer(_ frame: PresentationFrame) -> Bool
    func close(_ reason: PresentationHub.CloseReason)
}

/// PresentationHub fans a session's presentation state out to the viewers subscribed to it.
@MainActor
public final class PresentationHub {
    public enum CloseReason: Equatable, Sendable {
        case stalled
        case stale
    }

    public enum SubscribeError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public struct SubscriberID: Hashable, Sendable {
        let generation: Int
    }

    private final class Subscriber {
        let session: UUID
        let generation: Int
        let sink: PresentationSink
        let mode: PresentationMode
        /// What the viewer's hello listed, unfiltered: some kinds name what the viewer does, not frames sent to it.
        let kinds: Set<String>
        var revision = 0
        var lastAck: Date
        /// Deltas published while the snapshot is being taken, held so they land after it.
        var held: [PresentationFrame.Body]? = []

        init(session: UUID, generation: Int, sink: PresentationSink, hello: PresentationHello, now: Date) {
            self.session = session
            self.generation = generation
            self.sink = sink
            mode = hello.mode
            kinds = Set(hello.kinds)
            lastAck = now
        }
    }

    /// The frame kinds this origin can produce.
    public static let supportedKinds = ["status", "hud", "notify", "context", "layout"]

    private let staleTimeout: TimeInterval
    private let now: () -> Date
    private var subscribers: [SubscriberID: Subscriber] = [:]
    private var lastGeneration = 0
    private var layouts: [UUID: PresentationLayout] = [:]
    private var grant = PresenterGrant()

    /// Called before replacing or releasing an existing holder.
    public var onPresenterWillChange: (@MainActor (UUID) -> Void)?
    /// Called after a new holder has received presenter.granted.
    public var onPresenterChanged: (@MainActor (UUID) -> Void)?
    /// Called after a release leaves no eligible viewer to take the role.
    public var onPresenterLost: (@MainActor (UUID) -> Void)?
    /// Called with what a session's current presenter sent about work it was handed. Frames of this kind
    /// from any other viewer are dropped before this is reached.
    public var onPresenterFrame: (@MainActor (UUID, PresentationFrame.Body) -> Void)?

    /// Called when any subscribed viewer marks its session seen.
    public var onSeen: (@MainActor (UUID) -> Void)?

    public init(staleTimeout: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.staleTimeout = staleTimeout
        self.now = now
    }

    /// Registers a viewer and sends it hello, then the snapshot, then whatever was published meanwhile.
    ///
    /// The subscriber is registered BEFORE `snapshot` runs, so a change made while the snapshot is taken is
    /// held and delivered after it and nothing falls between the two.
    @discardableResult
    public func subscribe(session: UUID, hello: PresentationHello, sink: PresentationSink,
                          snapshot: () -> PresentationSnapshot) throws -> SubscriberID {
        guard let version = PresentationCodec.negotiatedVersion(ours: PresentationCodec.version,
                                                                theirs: hello.version) else {
            throw SubscribeError.unsupportedVersion(hello.version)
        }
        lastGeneration += 1
        let id = SubscriberID(generation: lastGeneration)
        let subscriber = Subscriber(session: session, generation: lastGeneration, sink: sink, hello: hello, now: now())
        subscribers[id] = subscriber

        let state = snapshot()
        if layouts[session] == nil { layouts[session] = state.layout }
        let held = subscriber.held ?? []
        subscriber.held = nil
        let kinds = Self.supportedKinds.filter(hello.kinds.contains)
        // presenter is offered only to a viewer that asked for it, so a slice-1 viewer stays a mirror
        let answer = PresentationHello(version: version, kinds: kinds, mode: hello.mode)
        for body in [.hello(answer), .snapshot(state)] + held {
            guard send(body, to: id) else { break }
        }
        return id
    }

    public func unsubscribe(_ id: SubscriberID) {
        let session = subscribers.removeValue(forKey: id)?.session
        if let session, subscriberCount(session: session) == 0 { layouts[session] = nil }
        if let session { release(id, session: session) }
    }

    /// Sends `body` to `session`'s presenter alone. False when there is none, or it stalled and was dropped.
    @discardableResult
    public func sendToPresenter(_ body: PresentationFrame.Body, session: UUID) -> Bool {
        guard let holder = grant.holder(of: session) else { return false }
        return send(body, to: holder)
    }

    func publishLayout(_ layout: PresentationLayout, session: UUID) {
        guard subscriberCount(session: session) > 0, layouts[session] != layout else { return }
        layouts[session] = layout
        publish(.layout(layout), session: session)
    }

    public func publish(_ body: PresentationFrame.Body, session: UUID) {
        for (id, subscriber) in subscribers where subscriber.session == session {
            if subscriber.held != nil {
                subscriber.held?.append(body)
                continue
            }
            send(body, to: id)
        }
    }

    /// Handles a frame a viewer sent. One from another generation is left over from an earlier connection.
    public func receive(_ frame: PresentationFrame, from id: SubscriberID) {
        guard let subscriber = subscribers[id], frame.gen == subscriber.generation else { return }
        switch frame.body {
        case .ack: subscriber.lastAck = now()
        case .seen: onSeen?(subscriber.session)
        case .ping: send(.ack, to: id)
        case .presenterAcquire:
            let previous = grant.holder(of: subscriber.session)
            let granted = grant.acquire(session: subscriber.session, by: id)
            if send(granted ? .presenterGranted : .presenterRefused, to: id), granted, previous == nil,
               grant.holder(of: subscriber.session) == id {
                onPresenterChanged?(subscriber.session)
            }
        case .presenterTake: takePresenter(id, session: subscriber.session)
        case .askResolve, .askRejected, .overlayRejected, .overlayClosed, .controlForwarded:
            guard grant.holder(of: subscriber.session) == id else { return }
            onPresenterFrame?(subscriber.session, frame.body)
        default: break
        }
    }

    /// Closes every subscriber whose last ack is older than the stale timeout and pings the rest. The owner of
    /// the streams calls this on its own timer.
    public func heartbeat() {
        let current = now()
        for (id, subscriber) in subscribers {
            if current.timeIntervalSince(subscriber.lastAck) > staleTimeout {
                drop(id, reason: .stale)
                continue
            }
            send(.ping, to: id)
        }
    }

    public func subscriberCount(session: UUID) -> Int {
        subscribers.values.count { $0.session == session }
    }

    /// Drops `session`'s presenter as stale, which passes the role to the next viewer that asked for it. For a holder
    /// that was handed work and never answered.
    public func dropPresenter(session: UUID) {
        if let holder = grant.holder(of: session) { drop(holder, reason: .stale) }
    }

    /// Whether a viewer holds `session`'s presenter role.
    public func hasPresenter(session: UUID) -> Bool { grant.holder(of: session) != nil }

    /// Whether `session`'s presenter listed `kind` in its hello.
    public func presenterSupports(_ kind: String, session: UUID) -> Bool {
        grant.holder(of: session).flatMap { subscribers[$0] }?.kinds.contains(kind) == true
    }

    /// Counts changes of `session`'s presenter, a grant and a loss alike.
    public func presenterGeneration(session: UUID) -> Int { grant.generation(of: session) }

    @discardableResult
    private func send(_ body: PresentationFrame.Body, to id: SubscriberID) -> Bool {
        guard let subscriber = subscribers[id] else { return false }
        let frame = PresentationFrame(gen: subscriber.generation, rev: subscriber.revision, body: body)
        guard subscriber.sink.offer(frame) else {
            drop(id, reason: .stalled)
            return false
        }
        subscriber.revision += 1
        return true
    }

    private func drop(_ id: SubscriberID, reason: CloseReason) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        if subscriberCount(session: subscriber.session) == 0 { layouts[subscriber.session] = nil }
        subscriber.sink.close(reason)
        release(id, session: subscriber.session)
    }

    private func takePresenter(_ id: SubscriberID, session: UUID) {
        let previous = grant.holder(of: session)
        if let previous, previous != id {
            onPresenterWillChange?(session)
            // A stalled dismissal may already have handed the role to another viewer.
            if grant.holder(of: session) != previous {
                if grant.holder(of: session) != id, subscribers[id] != nil { takePresenter(id, session: session) }
                return
            }
        }
        guard subscribers[id] != nil else { return }
        grant.transfer(session: session, to: id)
        if let previous, previous != id { send(.presenterRefused, to: previous) }
        if send(.presenterGranted, to: id), previous != id, grant.holder(of: session) == id {
            onPresenterChanged?(session)
        }
    }

    private func release(_ id: SubscriberID, session: UUID) {
        guard grant.holder(of: session) == id else { return }
        onPresenterWillChange?(session)
        guard grant.holder(of: session) == id else { return }
        _ = grant.release(id)
        let next = subscribers.filter {
            $0.value.session == session && $0.value.mode == .presenter && $0.value.held == nil
        }.keys.min { $0.generation < $1.generation }
        guard let next else {
            onPresenterLost?(session)
            return
        }
        _ = grant.acquire(session: session, by: next)
        if send(.presenterGranted, to: next), grant.holder(of: session) == next {
            onPresenterChanged?(session)
        }
    }
}
