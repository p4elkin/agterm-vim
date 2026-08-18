import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer.setNormalMode`, the real function behind `mode on|off|toggle`.
/// `ControlDispatcherTests` stop at `MockControlActions`, so nothing below the dispatcher — the idempotent
/// no-op, the two refusals and their exact wording — is exercised anywhere else. The refusals matter more
/// than most: a caller told `ok` over a mode that never armed sends bare keys straight to the shell.
@MainActor
final class ControlServerNormalModeTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!
    private var window: NSWindow!
    private var registeredDashboardIDs: Set<WindowInfo.ID> = []

    private let modalError = "cannot enter normal mode: zoom, the dashboard or a picker owns the keyboard, "
        + "or agterm is not frontmost"

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-normal-mode-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library,
                                             settingsStore: SettingsStore(directory: stateDir)),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // hosted tests cannot make a real key window, and every entry needs one; see `AppActions`.
            actions.keyWindowProvider = { [window] in window }
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NormalModeController.shared.exit()
            for id in registeredDashboardIDs {
                DashboardControllerRegistry.shared.unregister(id)
            }
            registeredDashboardIDs.removeAll()
            window.orderOut(nil)
            window = nil
            server = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testRequestingTheStateTheModeIsAlreadyInIsAnIdempotentOk() throws {
        XCTAssertEqual(server.setNormalMode(.off), ControlResponse(ok: true))
        XCTAssertFalse(NormalModeController.shared.isActive)

        XCTAssertEqual(server.setNormalMode(.on), ControlResponse(ok: true))
        XCTAssertTrue(NormalModeController.shared.isActive)
        // the second `on` must answer from the mode's own state, not re-run the entry preconditions: with the
        // window gone, re-entering would refuse and report a mode the caller can see is on.
        library.closeWindow(try XCTUnwrap(library.activeWindowID))
        XCTAssertEqual(server.setNormalMode(.on), ControlResponse(ok: true))
        XCTAssertTrue(NormalModeController.shared.isActive)
    }

    func testLeavingTheModeNeedsNoWindowAndToggleReturnsToOff() throws {
        XCTAssertEqual(server.setNormalMode(.toggle), ControlResponse(ok: true))
        XCTAssertTrue(NormalModeController.shared.isActive)

        library.closeWindow(try XCTUnwrap(library.activeWindowID))

        XCTAssertEqual(server.setNormalMode(.toggle), ControlResponse(ok: true))
        XCTAssertFalse(NormalModeController.shared.isActive, "leaving is unconditional; only entering gates")
    }

    func testEnteringWithNoOpenWindowErrors() throws {
        library.closeWindow(try XCTUnwrap(library.activeWindowID))

        XCTAssertEqual(server.setNormalMode(.on),
                       ControlResponse(ok: false, error: "no open window"))
        XCTAssertFalse(NormalModeController.shared.isActive)
    }

    /// The zoom / dashboard / picker gate `AppActions.enterNormalMode` shares with the keymap path swallows
    /// the entry silently, so the command has to notice the mode did not arm and say so.
    func testEnteringIsRefusedWhileAModalOwnsTheKeyboard() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let dashboard = DashboardController()
        dashboard.open(members: [DashboardMember(session: UUID(), surface: .primary)])
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        registeredDashboardIDs.insert(windowID)

        XCTAssertEqual(server.setNormalMode(.on), ControlResponse(ok: false, error: modalError))
        XCTAssertFalse(NormalModeController.shared.isActive)

        dashboard.close()

        XCTAssertEqual(server.setNormalMode(.on), ControlResponse(ok: true),
                       "the same request succeeds once the modal releases the keyboard")
        XCTAssertTrue(NormalModeController.shared.isActive)
    }
}
