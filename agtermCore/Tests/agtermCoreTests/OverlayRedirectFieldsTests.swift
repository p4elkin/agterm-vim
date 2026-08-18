import Foundation
import Testing
@testable import agtermCore

// The eight-site carry of `mirrorsSession` and `viewer` through Session -> Snapshot -> AppStore -> the wire.
// The round trip is what catches a site that got the value written but never read back (#360-style).
@MainActor
struct OverlayRedirectFieldsTests {
    @Test func bothFieldsAreNilByDefault() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.mirrorsSession == nil)
        #expect(session.viewer == nil)
    }

    @Test func mirrorsSessionRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.mirrorsSession = OverlayMirrorSource(host: "p4studio.local", session: "s1")
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].mirrorsSession
            == OverlayMirrorSource(host: "p4studio.local", session: "s1"))
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.workspaces[0].sessions[0].mirrorsSession
            == OverlayMirrorSource(host: "p4studio.local", session: "s1"))
    }

    @Test func viewerRoundTripsThroughAFullEncodeAndDecode() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.viewer = OverlayViewer(host: "p4air.local", row: "r7", confirmedAt: 1_000_000)
        let data = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(decoded.workspaces[0].sessions[0].viewer
            == OverlayViewer(host: "p4air.local", row: "r7", confirmedAt: 1_000_000))
        let restored = makeStore()
        restored.restore(from: decoded)
        #expect(restored.workspaces[0].sessions[0].viewer?.host == "p4air.local")
        #expect(restored.workspaces[0].sessions[0].viewer?.row == "r7")
        // the whole staleness rule hangs on this field surviving the trip; a restored viewer that lost its
        // timestamp would read as confirmed at the epoch, i.e. permanently stale.
        #expect(restored.workspaces[0].sessions[0].viewer?.confirmedAt == 1_000_000)
    }

    @Test func aSessionWithNeitherFieldSetOmitsBothKeysFromTheJSON() throws {
        // matches "backward compatible": a tree with no pairing serializes exactly as it did before the
        // fields existed.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let json = try String(decoding: JSONEncoder().encode(store.snapshot()), as: UTF8.self)
        #expect(!json.contains("mirrorsSession"))
        #expect(!json.contains("\"viewer\""))
    }

    @Test func theMirrorsCwdRoundTripsThroughAFullEncodeAndDecode() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.mirrorsSession = OverlayMirrorSource(host: "p4studio.local", session: "s1", cwd: "/w/agterm")
        let data = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(decoded.workspaces[0].sessions[0].mirrorsSession?.cwd == "/w/agterm")
    }

    // The field arrived after the pairing did, so every snapshot written before it must still decode — and a
    // throw here does not cost one field, it fails the whole SessionSnapshot and wipes the tree above it.
    @Test func aMirrorsPairingStoredBeforeTheCwdFieldExistedDecodesWithANilCwd() throws {
        let json = #"""
        {"id":"\#(UUID().uuidString)","cwd":"/tmp",
         "mirrorsSession":{"host":"p4studio.local","session":"s1"}}
        """#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.mirrorsSession == OverlayMirrorSource(host: "p4studio.local", session: "s1"))
        #expect(snap.mirrorsSession?.cwd == nil)
    }

    @Test func aPairingWithNoCwdOmitsTheKeyFromTheJSON() throws {
        let source = OverlayMirrorSource(host: "p4studio.local", session: "s1")
        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(!json.contains("cwd"))
    }

    @Test func malformedViewerOnDiskDecodesToNilRatherThanThrowing() throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","viewer":"not-an-object"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.viewer == nil)
    }

    @Test func malformedMirrorsSessionOnDiskDecodesToNilRatherThanThrowing() throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","mirrorsSession":42}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.mirrorsSession == nil)
    }

    @Test func legacySnapshotWithoutEitherFieldDecodesNil() throws {
        // a throw here would fail the whole SessionSnapshot, which wipes the tree above it.
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","foregroundCommand":["claude"]}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.mirrorsSession == nil)
        #expect(snap.viewer == nil)
        #expect(snap.foregroundCommand == ["claude"])
    }

    @Test func bothAppearInTheTreeNodeWhenSet() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         mirrorsSession: OverlayMirrorSource(host: "p4studio.local", session: "s1"),
                                         viewer: OverlayViewer(host: "p4air.local", row: "r7", confirmedAt: 1_000_000))
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(json.contains("mirrorsSession"))
        #expect(json.contains("\"viewer\""))
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.mirrorsSession == session.mirrorsSession)
        #expect(decoded.viewer == session.viewer)
    }

    @Test func bothAreOmittedFromTheTreeNodeWhenNil() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("mirrorsSession"))
        #expect(!json.contains("\"viewer\""))
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.mirrorsSession == nil)
        #expect(decoded.viewer == nil)
    }
}
