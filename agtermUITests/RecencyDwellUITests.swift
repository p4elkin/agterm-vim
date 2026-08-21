import XCTest

/// The dwell threshold, driven through the real UI rather than the store.
///
/// `AppStoreRecencyDwellTests` already covers the semantics thoroughly, but every timing case there
/// sets a dwell longer than the test can run and fires it with `recencyDwellDebouncer.flush()`, so
/// nothing ever waits. That leaves two things unexercised, and both are what a user actually meets:
/// the REAL timer, and the path from `settings.json` through to the Ctrl-Tab switcher.
///
/// So these tests wait. `s5` is the shortest configurable dwell, which sets the floor on how quick
/// this file can be; the suppression cases use `s60` instead, because proving a session did NOT get
/// recorded needs a threshold nothing can cross while the test runs.
///
/// Asserted through the persisted `selectedSessionID`, the same way `SessionSwitcherUITests` does —
/// the recency order itself is not in the snapshot, so Ctrl-Tab is how it is observed.
@MainActor
final class RecencyDwellUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    // MARK: - The suppression the feature exists for

    /// Walking past sessions must not put them in the switcher's reach. This is the whole point of
    /// the setting: before it, every row passed through counted as visited and pushed the real work
    /// down.
    ///
    /// ⚠️ Under a dwell, ADDING a session arms like any other selection — it does not record. The
    /// unit fixture looks like it says otherwise, but it creates its sessions BEFORE setting
    /// `recencyDwell`, so those were recorded by the zero-wait path and then removed. Read the
    /// ordering there, not the comment.
    ///
    /// Paired with `testImmediateRestoresRecordingOnSelection`, which runs the same shape of
    /// interaction and DOES move: same actions, different dwell, opposite outcome.
    func testWalkingPastSessionsDoesNotReorderTheSwitcher() throws {
        launch(dwell: "s60")
        let first = try XCTUnwrap(firstSessionID())
        _ = try addSession(expecting: 2)

        // The walk: select the other row and come straight back, each well under the 60s dwell.
        let rows = app.staticTexts.matching(identifier: "session-row")
        XCTAssertEqual(rows.count, 2, "both rows should be in the sidebar")
        rows.element(boundBy: 0).click()
        XCTAssertTrue(poll { self.selectedID() == first }, "the walk should reach the first row")
        rows.element(boundBy: 1).click()
        XCTAssertTrue(poll { self.selectedID() != first }, "the walk should reach the second row")
        rows.element(boundBy: 0).click()
        XCTAssertTrue(poll { self.selectedID() == first }, "the walk should come back")

        // Nothing selected during this test served its dwell, so nothing it touched is reachable:
        // Ctrl+Tab has nowhere to go and the selection must not move. Under `immediate` the same
        // walk records every step and Ctrl+Tab does move -- that is the paired test.
        let settled = try XCTUnwrap(selectedID())
        app.typeKey("\t", modifierFlags: .control)
        XCTAssertFalse(
            poll({ self.selectedID() != settled }, timeout: 2),
            "a row merely passed through must not become reachable by Ctrl+Tab")
    }

    // MARK: - The two ways a session DOES get recorded

    /// The real timer, not a flushed debouncer: stay on a session past the dwell and it joins the order.
    func testStayingPastTheDwellRecordsTheSession() throws {
        launch(dwell: "s5")
        let first = try XCTUnwrap(firstSessionID())

        // `first` is selected at launch; wait out its dwell so it is genuinely in the order.
        Thread.sleep(forTimeInterval: 6)

        let second = try addSession(expecting: 2)
        Thread.sleep(forTimeInterval: 6)

        // Both have now served the dwell, so the order is [second, first] and Ctrl+Tab lands on first.
        app.typeKey("\t", modifierFlags: .control)
        XCTAssertTrue(
            poll { self.selectedID() == first },
            "a session selected longer than the dwell should be the Ctrl+Tab target")

        // And the commit moves `first` to the front, so going back reaches `second`.
        app.typeKey("\t", modifierFlags: .control)
        XCTAssertTrue(poll { self.selectedID() == second }, "a second Ctrl+Tab should switch back")
    }

    /// Typing records the pending session immediately, without waiting the dwell out. Under `s60`
    /// nothing can be recorded by elapsed time, so a successful switch can only come from the keystroke.
    func testTypingRecordsTheSessionWithoutWaitingOutTheDwell() throws {
        launch(dwell: "s60")
        let first = try XCTUnwrap(firstSessionID())

        app.typeText("x")
        XCTAssertTrue(poll { self.selectedID() == first }, "typing should not move the selection")

        let second = try addSession(expecting: 2)
        app.typeText("y")

        // `first` was recorded by its keystroke and `second` by its own, so the order is populated
        // despite a 60s threshold neither could have crossed.
        app.typeKey("\t", modifierFlags: .control)
        XCTAssertTrue(
            poll { self.selectedID() == first },
            "a typed-in session should join the order without serving the dwell")
    }

    // MARK: - The escape hatch

    /// `immediate` must reproduce the pre-dwell behaviour exactly — it is the setting's way out, and a
    /// user who dislikes the feature gets nothing else. Mirrors `SessionSwitcherUITests`.
    /// Deliberately the SAME walk as `testWalkingPastSessionsDoesNotReorderTheSwitcher`, so the two
    /// differ only in the setting. Same clicks, same Ctrl+Tab; there the selection cannot move, here
    /// it must. Either test alone proves much less -- a suppression assertion passes just as well
    /// when the switcher is broken outright.
    func testImmediateRestoresRecordingOnSelection() throws {
        launch(dwell: "immediate")
        let first = try XCTUnwrap(firstSessionID())
        let second = try addSession(expecting: 2)
        XCTAssertNotEqual(second, first, "the new session should be selected after add")

        let rows = app.staticTexts.matching(identifier: "session-row")
        XCTAssertEqual(rows.count, 2, "both rows should be in the sidebar")
        rows.element(boundBy: 0).click()
        XCTAssertTrue(poll { self.selectedID() == first }, "the walk should reach the first row")
        rows.element(boundBy: 1).click()
        XCTAssertTrue(poll { self.selectedID() != first }, "the walk should reach the second row")
        rows.element(boundBy: 0).click()
        XCTAssertTrue(poll { self.selectedID() == first }, "the walk should come back")

        // Every step of that walk was recorded on selection, so the row passed through is reachable.
        let settled = try XCTUnwrap(selectedID())
        app.typeKey("\t", modifierFlags: .control)
        XCTAssertTrue(
            poll { self.selectedID() != settled },
            "with no dwell, a passed-through row should be reachable by Ctrl+Tab")
    }

    /// An absent key is `s20`, NOT the zero-wait case every sibling enum falls back to. An existing
    /// settings.json has no key, so a threshold that only worked once configured would reach nobody.
    func testAnUnsetDwellIsNotImmediate() throws {
        launch(dwell: nil)
        let first = try XCTUnwrap(firstSessionID())
        _ = try addSession(expecting: 2)

        // Exactly the walk from the suppression case. Under the 20s default nothing here can serve
        // its dwell, so an unset key must suppress just as `s60` does. If the fallback were
        // `immediate` -- the zero-wait case every sibling enum falls back to -- every step would be
        // recorded and Ctrl+Tab would move, which is what the `immediate` test asserts.
        let rows = app.staticTexts.matching(identifier: "session-row")
        rows.element(boundBy: 0).click()
        XCTAssertTrue(poll { self.selectedID() == first }, "the walk should reach the first row")
        rows.element(boundBy: 1).click()
        XCTAssertTrue(poll { self.selectedID() != first }, "the walk should reach the second row")
        rows.element(boundBy: 0).click()
        XCTAssertTrue(poll { self.selectedID() == first }, "the walk should come back")

        let settled = try XCTUnwrap(selectedID())
        app.typeKey("\t", modifierFlags: .control)
        XCTAssertFalse(
            poll({ self.selectedID() != settled }, timeout: 2),
            "an unset dwell must suppress like s20, not record like `immediate`")
    }

    // MARK: - Helpers

    /// Seeds `settings.json` before launch — the control channel has no `settings.*` command, so this
    /// is the only way to exercise one, the same as every other settings-dependent suite here.
    private func launch(dwell: String?) {
        if let dwell {
            let data = try! JSONSerialization.data(withJSONObject: ["recencyDwell": dwell])
            try! data.write(to: stateDir.appendingPathComponent("settings.json"))
        }
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(
            app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20),
            "seeded session should exist")
    }

    /// ⚠️ Both waits are load-bearing, and `isHittable` is the one that matters. AppKit reports the
    /// menu item as EXISTING before the menu has been laid out, and clicking it in that window throws
    /// `Invalid parameter not satisfying: point.x != INFINITY` — the item has no frame to aim at yet.
    /// Measured: without this, roughly one run in three failed at the `New Session` click.
    private func addSession(expecting count: Int) throws -> String {
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5), "the File menu should be in the menu bar")
        fileMenu.click()
        let newSession = app.menuItems["New Session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "File > New Session should appear")
        XCTAssertTrue(poll { newSession.isHittable }, "File > New Session should get a frame to click")
        newSession.click()
        XCTAssertTrue(poll { self.sessionCount() == count }, "session \(count) should be added")
        return try XCTUnwrap(selectedID())
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func snapshot() -> [String: Any]? {
        let file = stateDir.windowSnapshotFile()
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func workspaces() -> [[String: Any]] { snapshot()?["workspaces"] as? [[String: Any]] ?? [] }
    private func sessionCount() -> Int {
        workspaces().reduce(0) { $0 + (($1["sessions"] as? [[String: Any]])?.count ?? 0) }
    }
    private func selectedID() -> String? { snapshot()?["selectedSessionID"] as? String }
    private func firstSessionID() -> String? {
        (workspaces().first?["sessions"] as? [[String: Any]])?.first?["id"] as? String
    }
}
