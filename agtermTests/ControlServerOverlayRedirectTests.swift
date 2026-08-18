import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the redirect decision inside `ControlServer.openSessionOverlay`.
///
/// The first two tests are the desk path — nine keymap chords go through this function with nobody watching
/// remotely — so they assert the overlay REALLY opened (`overlayActive`), not merely that the response said ok.
@MainActor
final class ControlServerOverlayRedirectTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var settingsStore: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-overlay-redirect-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            let actions = AppActions(library: library)
            settingsStore = SettingsStore(directory: stateDir)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: settingsStore),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
            OverlayRedirectController.shared.setEnabled(false)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            OverlayRedirectController.shared.setEnabled(false)
            server = nil
            settingsStore = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func options(follow: Bool = false, resolved: Bool = false) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: "true", cwd: nil, wait: false, sizePercent: nil,
                                         backgroundColor: nil, follow: follow, pane: nil, resolved: resolved)
    }

    private func makeSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }

    private func freshViewer() -> OverlayViewer {
        OverlayViewer(host: "laptop", row: "row-7", confirmedAt: Date().timeIntervalSince1970)
    }

    // MARK: the path that must not change

    func testToggleOffOpensAPlainLocalOverlayWhateverThePairing() throws {
        let (_, session) = try makeSession()
        session.mirrorsSession = OverlayMirrorSource(host: "workstation", session: "abc")
        session.viewer = freshViewer()

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options())

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(response.result?.overlayRedirect, "the toggle being off must not produce a redirect answer")
        XCTAssertTrue(session.overlayActive, "the desk path must actually open the overlay")
    }

    func testToggleOnWithNoPairingOpensAPlainLocalOverlay() throws {
        let (_, session) = try makeSession()
        OverlayRedirectController.shared.setEnabled(true)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options())

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(response.result?.overlayRedirect)
        XCTAssertTrue(session.overlayActive, "an unpaired row must open its overlay here")
    }

    func testAStaleViewerOpensLocally() throws {
        let (_, session) = try makeSession()
        session.viewer = OverlayViewer(host: "laptop", row: "row-7",
                                       confirmedAt: Date().timeIntervalSince1970 - OverlayRedirect.stalenessWindow - 1)
        OverlayRedirectController.shared.setEnabled(true)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options())

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(response.result?.overlayRedirect)
        XCTAssertTrue(session.overlayActive)
    }

    // MARK: the resolved re-send closes the loop

    func testAResolvedRequestOpensPlainlyAndNeverRedirects() throws {
        let (_, session) = try makeSession()
        session.viewer = freshViewer()
        OverlayRedirectController.shared.setEnabled(true)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: options(resolved: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(response.result?.overlayRedirect, "a resolved re-send must not decide again")
        XCTAssertTrue(session.overlayActive, "agtermctl's wrapped re-send is what actually opens the overlay")
    }

    // MARK: the two redirect outcomes answer without opening

    func testMirrorsPairingAnswersWithTheSourceHostAndOpensNothing() throws {
        let (_, session) = try makeSession()
        session.mirrorsSession = OverlayMirrorSource(host: "workstation", session: "abc")
        OverlayRedirectController.shared.setEnabled(true)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options())

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.overlayRedirect,
                       ControlOverlayRedirect(outcome: .mirrorOf, host: "workstation"))
        XCTAssertFalse(session.overlayActive, "phase one must open nothing")
        XCTAssertEqual(response.result?.id, session.id.uuidString,
                       "agtermctl re-sends against the resolved session, not the target string")
    }

    /// The pairing's cwd is the workstation directory `agtermctl` cd's into. Phase one has to hand it over —
    /// the CLI's own process directory on a mirrored row is `$HOME`, which exists on both machines and so
    /// fails silently instead of erroring.
    func testMirrorsPairingAnswersWithTheRecordedCwd() throws {
        let (_, session) = try makeSession()
        session.mirrorsSession = OverlayMirrorSource(host: "workstation", session: "abc", cwd: "/w/agterm")
        OverlayRedirectController.shared.setEnabled(true)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options())

        XCTAssertEqual(response.result?.overlayRedirect,
                       ControlOverlayRedirect(outcome: .mirrorOf, host: "workstation", cwd: "/w/agterm"))
        XCTAssertFalse(session.overlayActive, "phase one must open nothing")
    }

    func testViewerPairingAnswersWithTheViewerHostAndRowAndOpensNothing() throws {
        let (_, session) = try makeSession()
        session.viewer = freshViewer()
        OverlayRedirectController.shared.setEnabled(true)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options())

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.overlayRedirect,
                       ControlOverlayRedirect(outcome: .watchedBy, host: "laptop", row: "row-7"))
        XCTAssertFalse(session.overlayActive, "phase one must open nothing")
    }

    /// `--follow` is the caller's flag and agtermctl carries it on the re-send, so phase one must not act on
    /// it: selecting here would pull the workstation's attention to a row whose overlay opens elsewhere.
    func testARedirectAnswerDoesNotFollow() throws {
        let (store, session) = try makeSession()
        let other = try XCTUnwrap(store.addSession(toWorkspace: XCTUnwrap(store.currentWorkspaceID),
                                                   cwd: NSHomeDirectory()))
        store.selectSession(other.id)
        session.viewer = freshViewer()
        OverlayRedirectController.shared.setEnabled(true)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNotNil(response.result?.overlayRedirect)
        XCTAssertEqual(store.selectedSessionID, other.id, "phase one must leave the selection where it was")
    }

    /// The local path keeps `--follow` exactly as it was.
    func testTheLocalPathStillFollows() throws {
        let (store, session) = try makeSession()
        store.selectSession(nil)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil, options: options(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    // MARK: session.pairing — the only path the mirror job writes through

    /// Swapping the two fields here would still pass every dispatcher-level test, since those stop at
    /// `MockControlActions`. This is the mutation itself.
    func testSetMirrorsWritesTheMirrorsFieldAndLeavesTheViewerAlone() throws {
        let (_, session) = try makeSession()
        let source = OverlayMirrorSource(host: "workstation", session: "abc")

        let response = server.setOverlayPairing(session.id.uuidString, window: nil, update: .setMirrors(source))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(session.mirrorsSession, source)
        XCTAssertNil(session.viewer)
    }

    /// ⚠️ `confirmedAt` is stamped by the RECEIVING host, never sent, so the two machines' clocks never have
    /// to agree — the whole staleness rule rests on that.
    func testSetViewerStampsTheConfirmationTimeFromThisHostsClock() throws {
        let (_, session) = try makeSession()
        let before = Date().timeIntervalSince1970

        let response = server.setOverlayPairing(session.id.uuidString, window: nil,
                                                update: .setViewer(host: "p4air", row: "row-9"))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(session.viewer?.host, "p4air")
        XCTAssertEqual(session.viewer?.row, "row-9")
        let stamped = try XCTUnwrap(session.viewer?.confirmedAt)
        XCTAssertGreaterThanOrEqual(stamped, before)
        XCTAssertLessThanOrEqual(stamped, Date().timeIntervalSince1970)
        XCTAssertNil(session.mirrorsSession)
    }

    func testClearingEachPairingNilsOnlyItsOwnField() throws {
        let (_, session) = try makeSession()
        session.mirrorsSession = OverlayMirrorSource(host: "workstation", session: "abc")
        session.viewer = freshViewer()

        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil, update: .clearViewer).ok)
        XCTAssertNil(session.viewer)
        XCTAssertNotNil(session.mirrorsSession, "clearing the viewer must not touch the mirrors pairing")

        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil, update: .clearMirrors).ok)
        XCTAssertNil(session.mirrorsSession)
    }

    func testAnUnknownSessionIsRejectedRatherThanSilentlyAccepted() {
        let response = server.setOverlayPairing(UUID().uuidString, window: nil, update: .clearViewer)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.hasPrefix("no such session"), true)
    }

    /// The persisted session node, read back off disk. `store.save()` cancels any pending debounced save
    /// and writes synchronously, so what this returns after a real pairing write is final.
    private func persisted(_ sessionID: UUID) throws -> SessionSnapshot? {
        let directory = stateDir.appendingPathComponent("windows", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { continue }
            for workspace in snapshot.workspaces {
                if let node = workspace.sessions.first(where: { $0.id == sessionID }) { return node }
            }
        }
        return nil
    }

    /// A pairing that really changes is persisted; a heartbeat that moves only `confirmedAt` is not. The
    /// mirror job sends one per mirrored row every 20 seconds, forever, and `store.save()` is the
    /// undebounced full-snapshot write of the whole tree, on the main actor.
    func testAViewerHeartbeatRefreshesTheStampWithoutRewritingTheWholeSnapshot() throws {
        let (_, session) = try makeSession()

        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil,
                                               update: .setViewer(host: "p4air", row: "row-9")).ok)
        let first = try XCTUnwrap(try persisted(session.id)?.viewer, "a NEW pairing is written to disk")

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil,
                                               update: .setViewer(host: "p4air", row: "row-9")).ok)

        XCTAssertGreaterThan(try XCTUnwrap(session.viewer?.confirmedAt), first.confirmedAt,
                             "the in-memory stamp is what the decision and the pill read, and it must move")
        XCTAssertEqual(try persisted(session.id)?.viewer?.confirmedAt, first.confirmedAt,
                       "a heartbeat must not rewrite the session tree")
    }

    /// The mirror job re-asserts the mirrors pairing on every pass to backfill rows created before this
    /// feature; an unchanged value must be just as free as a viewer heartbeat.
    func testReAssertingTheSameMirrorsPairingDoesNotRewriteTheSnapshot() throws {
        let (_, session) = try makeSession()
        let source = OverlayMirrorSource(host: "workstation", session: "abc")

        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil, update: .setMirrors(source)).ok)
        XCTAssertEqual(try persisted(session.id)?.mirrorsSession, source)

        // a changed pairing IS saved, so mutate another persisted field behind the server's back and
        // re-assert: an unchanged write leaves the divergence on disk, a saving one would erase it.
        session.customName = "renamed-between-passes"
        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil, update: .setMirrors(source)).ok)

        XCTAssertEqual(session.mirrorsSession, source)
        XCTAssertNotEqual(try persisted(session.id)?.customName, "renamed-between-passes",
                          "re-asserting an unchanged pairing must not rewrite the session tree")
    }

    /// The same rule for a pairing whose CWD alone moved: that happens every time the human cd's on the far
    /// side, and it is re-asserted every pass, so persisting it would put the undebounced full-tree write
    /// behind an ordinary `cd`. The in-memory value is still what the redirect reads.
    func testAMirrorsPairingThatOnlyMovedItsCwdIsNotWrittenToDisk() throws {
        let (_, session) = try makeSession()
        let atHome = OverlayMirrorSource(host: "workstation", session: "abc", cwd: "/Users/sasha")
        let atRepo = OverlayMirrorSource(host: "workstation", session: "abc", cwd: "/w/agterm")

        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil, update: .setMirrors(atHome)).ok)
        session.customName = "renamed-between-passes"
        XCTAssertTrue(server.setOverlayPairing(session.id.uuidString, window: nil, update: .setMirrors(atRepo)).ok)

        XCTAssertEqual(session.mirrorsSession, atRepo, "the redirect reads the live value, and it must move")
        XCTAssertNotEqual(try persisted(session.id)?.customName, "renamed-between-passes",
                          "a cwd-only move must not rewrite the session tree")
    }

    // MARK: overlay-redirect.toggle

    func testTheToggleCommandFlipsTheControllerAndPersistsThroughSettings() throws {
        XCTAssertTrue(server.setOverlayRedirectToggle(.on).ok)
        XCTAssertTrue(OverlayRedirectController.shared.isEnabled)
        XCTAssertEqual(settingsStore.load().overlayRedirectEnabled, true, "the toggle must survive a restart")

        // idempotent: an `on` over an already-on toggle is an early return, not a second write
        XCTAssertTrue(server.setOverlayRedirectToggle(.on).ok)
        XCTAssertTrue(OverlayRedirectController.shared.isEnabled)

        XCTAssertTrue(server.setOverlayRedirectToggle(.toggle).ok)
        XCTAssertFalse(OverlayRedirectController.shared.isEnabled)
        XCTAssertNil(settingsStore.load().overlayRedirectEnabled, "off is persisted as an absent key")
    }

    /// `SettingsModel.init` seeds the controller from the saved value, which is what makes the toggle
    /// survive a relaunch rather than merely be written to disk.
    func testALaunchWithTheToggleSavedOnArmsTheControllerAgain() throws {
        var settings = settingsStore.load()
        settings.overlayRedirectEnabled = true
        try settingsStore.save(settings)
        OverlayRedirectController.shared.setEnabled(false)

        _ = SettingsModel(library: library, settingsStore: settingsStore)

        XCTAssertTrue(OverlayRedirectController.shared.isEnabled)
    }

}
