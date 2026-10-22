import Foundation
import Testing
@testable import agtermCore

/// An origin store and its hub, and viewer stores with real presentation clients, joined by a queue in
/// place of ssh. Frames are delivered by `pump`, so nothing arrives inside the call that sent it.
@MainActor
final class RemoteNameRoundTripTests {
    final class Wire {
        var queue: [() -> Void] = []

        func pump() {
            while !queue.isEmpty { queue.removeFirst()() }
        }
    }

    final class OriginSink: PresentationSink {
        let wire: Wire
        let deliver: @MainActor (Data) -> Void
        init(wire: Wire, deliver: @escaping @MainActor (Data) -> Void) {
            self.wire = wire
            self.deliver = deliver
        }
        func offer(_ frame: PresentationFrame) -> Bool {
            guard let line = try? PresentationCodec.encode(frame) else { return false }
            let deliver = deliver
            wire.queue.append { MainActor.assumeIsolated { deliver(line.dropLast()) } }
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}
    }

    final class Link: RemotePresentationLink {
        let wire: Wire
        let receive: @MainActor (PresentationFrame) -> Void
        var up = true
        init(wire: Wire, receive: @escaping @MainActor (PresentationFrame) -> Void) {
            self.wire = wire
            self.receive = receive
        }
        func send(_ line: Data) {
            guard up, let frame = try? PresentationCodec.decode(line.dropLast()) else { return }
            let receive = receive
            wire.queue.append { MainActor.assumeIsolated { receive(frame) } }
        }
        func stop() { up = false }
    }

    /// Plays `agtermctl zmx present`: the first frame a link sends is the hello that subscribes it.
    final class Transport: RemotePresentationTransport {
        let wire: Wire
        let hub: PresentationHub
        let origin: AppStore
        let session: UUID
        var links: [Link] = []

        init(wire: Wire, hub: PresentationHub, origin: AppStore, session: UUID) {
            self.wire = wire
            self.hub = hub
            self.origin = origin
            self.session = session
        }

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            var subscriber: PresentationHub.SubscriberID?
            let sink = OriginSink(wire: wire, deliver: onLine)
            let link = Link(wire: wire) { [hub, origin, session] frame in
                guard let id = subscriber else {
                    guard case .hello(let hello) = frame.body else { return }
                    subscriber = try? hub.subscribe(session: session, hello: hello, sink: sink) {
                        origin.presentationSnapshot(forSession: session)
                    }
                    return
                }
                hub.receive(frame, from: id)
            }
            links.append(link)
            return link
        }
    }

    struct Viewer {
        let store: AppStore
        let row: Session
        let client: RemotePresentationClient
    }

    let wire = Wire()
    let hub = PresentationHub(staleTimeout: 30)
    let origin = makeStore()
    let session: Session

    init() throws {
        origin.presentationHub = hub
        let ws = origin.addWorkspace(name: "work")
        session = try #require(origin.addSession(toWorkspace: ws.id, cwd: "/home/sasha"))
        hub.onRename = { [origin] id, name in origin.renameFromViewer(id, to: name) }
    }

    /// The wiring `ControlServer` does for a remote row, against a fresh viewer store.
    func viewer(named name: String? = "sasha") throws -> Viewer {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let row = try #require(store.addSession(toWorkspace: ws.id, cwd: "/Users/sasha", name: name, remoteHost: "p4linux"))
        store.bindRemote(RemoteBinding(remoteSessionID: session.id.uuidString,
                                       daemonsByLocalPane: [row.paneIdentity: "d-left"], presentationVersion: 1),
                         forSession: row.id)
        let id = row.id
        var client: RemotePresentationClient?
        let effects = RemotePresentationEffects(
            status: { _ in }, snapshotStatus: { _ in }, hud: { _ in }, notify: { _ in }, connection: { _ in },
            name: { store.applyRemoteName($0, forSession: id) },
            snapshotName: { name in
                if store.applyRemoteSnapshotName(name, forSession: id) { client?.rename(row.customName) }
            },
            warn: { Issue.record("stream warning: \($0)") })
        let transport = Transport(wire: wire, hub: hub, origin: origin, session: session.id)
        let made = RemotePresentationClient(argv: ["present"], presentationVersion: 1, transport: transport,
                                            effects: effects)
        client = made
        store.onRemoteSessionRenamed = { _, name in client?.rename(name) }
        return Viewer(store: store, row: row, client: made)
    }

    @Test func aRenameOnTheViewerReachesTheOriginAndItsEchoEndsThePending() throws {
        let mac = try viewer()
        mac.client.start()
        wire.pump()
        #expect(mac.row.customName == nil)

        mac.store.renameSession(mac.row.id, to: "labels preservation")
        #expect(mac.row.remotePresentation?.namePending == true)
        wire.pump()

        #expect(session.customName == "labels preservation")
        #expect(mac.row.customName == "labels preservation")
        #expect(mac.row.remotePresentation?.namePending == false)
    }

    @Test func aRenameOnTheOriginReachesTheViewer() throws {
        let mac = try viewer()
        mac.client.start()
        wire.pump()

        origin.renameSession(session.id, to: "Agterm row label restart persistence")
        wire.pump()

        #expect(mac.row.customName == "Agterm row label restart persistence")
        #expect(mac.row.remotePresentation?.namePending == false)
    }

    @Test func aRenameMadeWhileDisconnectedGoesOutWithTheNextSnapshot() throws {
        origin.renameSession(session.id, to: "older")
        let mac = try viewer(named: "older")
        mac.store.renameSession(mac.row.id, to: "parking")
        #expect(mac.row.remotePresentation?.namePending == true)

        mac.client.start()
        wire.pump()

        #expect(session.customName == "parking")
        #expect(mac.row.customName == "parking")
        #expect(mac.row.remotePresentation?.namePending == false)
    }

    @Test func aBlankRenameClearsTheNameOnBothSides() throws {
        origin.renameSession(session.id, to: "6.4.11 stack")
        let mac = try viewer(named: "6.4.11 stack")
        mac.client.start()
        wire.pump()

        mac.store.renameSession(mac.row.id, to: "  ")
        wire.pump()

        #expect(session.customName == nil)
        #expect(mac.row.customName == nil)
        #expect(mac.row.remotePresentation?.namePending == false)
    }

    @Test func twoViewersRenamingAtOnceEndOnTheOriginsName() throws {
        let first = try viewer()
        let second = try viewer()
        first.client.start()
        second.client.start()
        wire.pump()

        first.store.renameSession(first.row.id, to: "a")
        second.store.renameSession(second.row.id, to: "b")
        wire.pump()

        #expect(session.customName == "b")
        #expect(first.row.customName == "b")
        #expect(second.row.customName == "b")
        #expect(first.row.remotePresentation?.namePending == false)
        #expect(second.row.remotePresentation?.namePending == false)
    }

    @Test func anAttachSeedThatIsNotACustomNameIsClearedByTheFirstSnapshot() throws {
        let mac = try viewer(named: "sasha")
        #expect(mac.row.customName == "sasha")

        mac.client.start()
        wire.pump()

        #expect(mac.row.customName == nil)
    }
}
