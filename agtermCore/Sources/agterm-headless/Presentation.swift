import agtermCore
import AgtermHeadlessKit
import Foundation
import Glibc

/// One viewer's `zmx present` connection after its ok reply: frames out through a bounded writer queue,
/// the viewer's lines in on a reader thread, both hopping to the main actor for the hub.
@MainActor
final class PresentationStream: PresentationSink {
    static let maxPending = 256

    let session: UUID
    private let fd: Int32
    private let writer = DispatchQueue(label: "agterm-headless.present.writer")
    private let hub: PresentationHub
    private let snapshot: @MainActor () -> PresentationSnapshot
    private let onClosed: @MainActor (PresentationStream) -> Void
    private var subscriber: PresentationHub.SubscriberID?
    private var pending = 0
    private var shut = false

    init(session: UUID, fd: Int32, hub: PresentationHub,
         snapshot: @escaping @MainActor () -> PresentationSnapshot,
         onClosed: @escaping @MainActor (PresentationStream) -> Void) {
        self.session = session
        self.fd = fd
        self.hub = hub
        self.snapshot = snapshot
        self.onClosed = onClosed
    }

    var subscribed: Bool { subscriber != nil }

    func start() {
        let fd = fd
        // strong on purpose: the reader keeps the stream alive until the viewer's side ends. The semaphore
        // bounds lines waiting for the main actor, so a fast viewer stalls on its own socket instead.
        let backlog = DispatchSemaphore(value: 64)
        Thread { [self] in
            while let line = UnixSocket.readLine(fd, limit: PresentationCodec.maxFrameBytes) {
                backlog.wait()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.receive(line) }
                    backlog.signal()
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.closed() } }
        }.start()
    }

    func offer(_ frame: PresentationFrame) -> Bool {
        guard !shut, pending < Self.maxPending, let line = try? PresentationCodec.encode(frame) else { return false }
        pending += 1
        let fd = fd
        writer.async { [weak self] in
            UnixSocket.writeAll(fd, line)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pending -= 1 } }
        }
        return true
    }

    func close(_: PresentationHub.CloseReason) { shutdown() }

    func shutdown() {
        guard !shut else { return }
        shut = true
        Glibc.shutdown(fd, Int32(SHUT_RDWR))
    }

    private func receive(_ line: Data) {
        guard let frame = try? PresentationCodec.decode(line) else { return shutdown() }
        if let subscriber {
            hub.receive(frame, from: subscriber)
            return
        }
        guard case .hello(let hello) = frame.body else { return shutdown() }
        subscriber = try? hub.subscribe(session: session, hello: hello, sink: self, snapshot: snapshot)
        if subscriber == nil { shutdown() }
    }

    private func closed() {
        if let subscriber { hub.unsubscribe(subscriber) }
        subscriber = nil
        shut = true
        let fd = fd
        writer.async { Glibc.close(fd) }
        onClosed(self)
    }
}

@MainActor
final class PresentationStreams: HeadlessStreams {
    private let library: WindowLibrary
    private let hub: PresentationHub
    private var streams: [PresentationStream] = []
    private var heartbeat: DispatchSourceTimer?

    init(library: WindowLibrary, hub: PresentationHub) {
        self.library = library
        self.hub = hub
    }

    func adopt(session: UUID, fd: Int32) -> ControlResponse? {
        guard let store = library.store(forSession: session) else {
            return ControlResponse(ok: false, error: "no such session: \(session.uuidString)")
        }
        guard var reply = try? JSONEncoder().encode(ControlResponse(ok: true, result: ControlResult(id: session.uuidString))) else {
            return ControlResponse(ok: false, error: "internal")
        }
        reply.append(UInt8(ascii: "\n"))
        UnixSocket.writeAll(fd, reply)
        let stream = PresentationStream(session: session, fd: fd, hub: hub,
                                        snapshot: { store.presentationSnapshot(forSession: session) },
                                        onClosed: { [weak self] closed in self?.streams.removeAll { $0 === closed } })
        streams.append(stream)
        stream.start()
        startHeartbeat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak stream] in
            MainActor.assumeIsolated { if stream?.subscribed == false { stream?.shutdown() } }
        }
        return nil
    }

    func closeStreams(session: UUID) {
        for stream in streams where stream.session == session { stream.shutdown() }
    }

    func adoptJob(fd: Int32, reply: ControlResponse, onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor () -> Void) -> (any HeadlessJobTransport)? {
        guard var line = try? JSONEncoder().encode(reply) else {
            Glibc.close(fd)
            return nil
        }
        line.append(UInt8(ascii: "\n"))
        guard UnixSocket.writeAll(fd, line) else {
            Glibc.close(fd)
            return nil
        }
        let stream = JobStream(fd: fd)
        stream.start(onLine: onLine, onClose: onClose)
        return stream
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.hub.heartbeat() } }
        timer.resume()
        heartbeat = timer
    }
}
