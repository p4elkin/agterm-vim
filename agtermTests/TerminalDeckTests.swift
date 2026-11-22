import AppKit
import SwiftUI
import XCTest
@testable import agterm
@testable import agtermCore

@MainActor
final class TerminalDeckTests: XCTestCase {
    func testHiddenHostsAreMeasuredOnlyAtTheDeckSize() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: DeckFixture(recorder: recorder, selected: 0))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize

        XCTAssertEqual(recorder.views.count, 96)
        XCTAssertEqual(Set(recorder.proposals.keys), Set(0..<96))
        XCTAssertTrue(recorder.proposals.values.allSatisfy { proposals in
            !proposals.isEmpty && proposals.allSatisfy { $0.width == 900 && $0.height == 750 }
        }, "terminal hosts must not receive speculative min/ideal/max size proposals")
        XCTAssertEqual(host.fittingSize, CGSize(width: 640, height: 400))
    }

    func testEveryHostStaysMountedAcrossSelectionAndResize() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: DeckFixture(recorder: recorder, selected: 0))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        let originalViews = recorder.views
        XCTAssertEqual(originalViews.count, 96)

        host.rootView = DeckFixture(recorder: recorder, selected: 95)
        host.frame.size = CGSize(width: 1000, height: 650)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(recorder.creations, 96)
        for index in 0..<96 {
            XCTAssertTrue(recorder.views[index] === originalViews[index])
            XCTAssertEqual(recorder.views[index]?.frame.size, CGSize(width: 700, height: 600))
        }
    }

    func testPlaceholderIsCenteredWithNoSessionSelected() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: TerminalDeck {
            DeckProbe(index: 0, recorder: recorder).frame(width: 100, height: 30)
        })
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        let placeholder = recorder.views[0]
        XCTAssertNotNil(placeholder)
        XCTAssertEqual(placeholder?.convert(placeholder?.bounds ?? .zero, to: host),
                       CGRect(x: 250, y: 185, width: 100, height: 30))
    }

    func testPublishesItsTopEdgeToTheDeck() {
        let recorder = DeckTopRecorder()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 50)
            TerminalDeck { DeckTopReader(recorder: recorder) }
        })
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(recorder.deckTop, 50)
    }

    func testAPaneAboveTheDeckTopIsLaidOutBelowIt() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: DeckPaneInset { DeckProbe(index: 0, recorder: recorder) }
            .environment(\.terminalDeckTop, 50))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(topEdge(of: recorder.views[0], in: host), 50)
        XCTAssertEqual(recorder.views[0]?.frame.height, 350)
    }

    func testAPaneAlreadyBelowTheDeckTopKeepsItsFrame() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 50)
            DeckPaneInset { DeckProbe(index: 0, recorder: recorder) }
        }
        .environment(\.terminalDeckTop, 20))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(topEdge(of: recorder.views[0], in: host), 50)
        XCTAssertEqual(recorder.views[0]?.frame.height, 350)
    }

    func testAnAsleepRowHostsNoPaneKeepsItsHudAndRemountsTheRenewedLinesOnWake() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-deck-sleep-\(UUID().uuidString)")
        let library = WindowLibrary(directory: stateDir)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let store = try XCTUnwrap(library.activeStore)
        let row = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: NSTemporaryDirectory(), remoteHost: "box"))
        row.hasSplit = true
        row.isSplit = true
        row.splitPaneIdentity = UUID()
        row.overlayActive = true
        row.hudSpec = HudSpec(message: "deploying")
        // a selected pane is visible and expedites its spawn past the pacer
        _ = store.selectSession(nil)
        library.onRowWake = { session in
            session.initialCommand = "renewed-left"
            session.splitInitialCommand = "renewed-right"
        }
        let keys = (0..<16).map { _ in UUID() }
        let pacer = SpawnPacer(interval: .seconds(60), now: { ContinuousClock().now }, schedule: { _, _ in })
        pacer.arm(order: keys, burst: [])
        var made: [(pane: String, line: String?, view: GhosttySurfaceView)] = []
        var others: [GhosttySurfaceView] = []
        func paced(_ pane: String, _ session: Session, _ line: String?) -> GhosttySurfaceView {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            view.useSpawnPacer(pacer, key: keys[made.count + others.count])
            if session.id == row.id { made.append((pane, line, view)) } else { others.append(view) }
            return view
        }
        let content = WindowContentView(
            windowID: try XCTUnwrap(library.activeWindowID), store: store, library: library,
            makeSurface: { paced("left", $0, $0.initialCommand) }, makeSplitSurface: { paced("right", $0, $0.splitInitialCommand) },
            makeOverlaySurface: { session, _ in paced("hud", session, nil) }, makeScratchSurface: { paced("scratch", $0, nil) },
            captureOnExit: nil, actions: AppActions(library: library), palette: PaletteController(),
            sessionSwitcher: SessionSwitcher(library: library, canSwitch: { false }),
            toolbarMode: .normal, chromeText: .white, attentionButtonEnabled: false, hiddenInterfaceElements: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            (made.map(\.view) + others).forEach { $0.teardown() }
            window.close()
        }
        window.contentView = NSHostingView(rootView: content.detailPane.frame(width: 800, height: 500))
        func pump(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func views(_ pane: String) -> [GhosttySurfaceView] { made.filter { $0.pane == pane }.map(\.view) }

        pump { views("left").count == 1 && views("right").count == 1 && views("hud").count == 1 }
        XCTAssertEqual(made.map(\.pane).sorted(), ["hud", "left", "right"])
        let hud = try XCTUnwrap(views("hud").first)

        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .command))
        let asleep = views("left") + views("right")
        pump { asleep.allSatisfy { $0.window == nil } }

        XCTAssertTrue(asleep.allSatisfy { $0.window == nil }, "an asleep row must host neither pane")
        XCTAssertEqual(made.count, 3, "an asleep row must not build a pane")
        XCTAssertNotNil(hud.window, "the mirrored HUD stays hosted")

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        pump { views("left").count == 2 && views("right").count == 2 }

        XCTAssertEqual(made.filter { $0.pane == "left" }.map(\.line), [nil, "renewed-left"])
        XCTAssertEqual(made.filter { $0.pane == "right" }.map(\.line), [nil, "renewed-right"])
        XCTAssertEqual(views("hud").count, 1, "the HUD is not rebuilt")
        XCTAssertNotNil(views("left").last?.window)
        XCTAssertNotNil(views("right").last?.window)
        XCTAssertTrue((made.map(\.view) + others).allSatisfy { !$0.isRealized }, "nothing may spawn in the test host")
    }

    func testASleepAndWakeWithNoUpdateBetweenRemountTheLeftPane() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-deck-nap-\(UUID().uuidString)")
        let library = WindowLibrary(directory: stateDir)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let store = try XCTUnwrap(library.activeStore)
        let row = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: NSTemporaryDirectory(), remoteHost: "box"))
        _ = store.selectSession(nil)
        library.onRowWake = { $0.initialCommand = "renewed-left" }
        let keys = (0..<16).map { _ in UUID() }
        let pacer = SpawnPacer(interval: .seconds(60), now: { ContinuousClock().now }, schedule: { _, _ in })
        pacer.arm(order: keys, burst: [])
        var made: [(pane: String, line: String?, view: GhosttySurfaceView)] = []
        func paced(_ pane: String, _ session: Session, _ line: String?) -> GhosttySurfaceView {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            view.useSpawnPacer(pacer, key: keys[made.count])
            made.append((session.id == row.id ? pane : "other", line, view))
            return view
        }
        let content = WindowContentView(
            windowID: try XCTUnwrap(library.activeWindowID), store: store, library: library,
            makeSurface: { paced("left", $0, $0.initialCommand) }, makeSplitSurface: { paced("right", $0, $0.splitInitialCommand) },
            makeOverlaySurface: { session, _ in paced("hud", session, nil) }, makeScratchSurface: { paced("scratch", $0, nil) },
            captureOnExit: nil, actions: AppActions(library: library), palette: PaletteController(),
            sessionSwitcher: SessionSwitcher(library: library, canSwitch: { false }),
            toolbarMode: .normal, chromeText: .white, attentionButtonEnabled: false, hiddenInterfaceElements: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            made.forEach { $0.view.teardown() }
            window.close()
        }
        window.contentView = NSHostingView(rootView: content.detailPane.frame(width: 800, height: 500))
        func pump(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func left() -> [(line: String?, view: GhosttySurfaceView)] {
            made.filter { $0.pane == "left" }.map { ($0.line, $0.view) }
        }
        pump { left().count == 1 }
        let old = try XCTUnwrap(left().first?.view)

        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .command))
        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        pump { left().count == 2 && old.window == nil }

        XCTAssertEqual(left().map(\.line), [nil, "renewed-left"])
        XCTAssertNil(old.window)
        XCTAssertNotNil(left().last?.view.window)
        XCTAssertTrue(made.allSatisfy { !$0.view.isRealized }, "nothing may spawn in the test host")
    }

    func testAWokenHiddenSplitWithRightFocusRemountsTheRightPane() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-deck-wake-\(UUID().uuidString)")
        let library = WindowLibrary(directory: stateDir)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let store = try XCTUnwrap(library.activeStore)
        let row = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: NSTemporaryDirectory(), remoteHost: "box"))
        let split = UUID()
        row.hasSplit = true
        row.splitPaneIdentity = split
        row.splitFocused = true
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [
            row.paneIdentity: ZmxSupport.daemonName(for: UUID()), split: ZmxSupport.daemonName(for: UUID()),
        ], presentationVersion: 1), forSession: row.id)
        _ = store.selectSession(nil)
        row.splitSurface = SleptPaneSurface()
        XCTAssertTrue(store.sleepRemoteRow(row.id, reason: .command))
        library.onRowWake = { session in
            session.initialCommand = "renewed-left"
            session.splitInitialCommand = "renewed-right"
        }
        let keys = (0..<16).map { _ in UUID() }
        let pacer = SpawnPacer(interval: .seconds(60), now: { ContinuousClock().now }, schedule: { _, _ in })
        pacer.arm(order: keys, burst: [])
        var made: [(pane: String, line: String?, view: GhosttySurfaceView)] = []
        func paced(_ pane: String, _ session: Session, _ line: String?) -> GhosttySurfaceView {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            view.useSpawnPacer(pacer, key: keys[made.count])
            made.append((session.id == row.id ? pane : "other", line, view))
            return view
        }
        let content = WindowContentView(
            windowID: try XCTUnwrap(library.activeWindowID), store: store, library: library,
            makeSurface: { paced("left", $0, $0.initialCommand) }, makeSplitSurface: { paced("right", $0, $0.splitInitialCommand) },
            makeOverlaySurface: { session, _ in paced("hud", session, nil) }, makeScratchSurface: { paced("scratch", $0, nil) },
            captureOnExit: nil, actions: AppActions(library: library), palette: PaletteController(),
            sessionSwitcher: SessionSwitcher(library: library, canSwitch: { false }),
            toolbarMode: .normal, chromeText: .white, attentionButtonEnabled: false, hiddenInterfaceElements: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            made.forEach { $0.view.teardown() }
            window.close()
        }
        window.contentView = NSHostingView(rootView: content.detailPane.frame(width: 800, height: 500))
        func pump(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(made.filter { $0.pane != "other" }.isEmpty, "an asleep row must not build a pane")

        XCTAssertTrue(store.wakeRemoteRow(row.id, reason: .shown, onScreen: true))
        pump { made.contains { $0.pane == "right" } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(made.filter { $0.pane != "other" }.map(\.pane), ["right"])
        XCTAssertEqual(made.first { $0.pane == "right" }?.line, "renewed-right")
        XCTAssertTrue(row.splitFocused)
        XCTAssertTrue(made.allSatisfy { !$0.view.isRealized }, "nothing may spawn in the test host")
    }

    private func topEdge(of view: NSView?, in host: NSView) -> CGFloat? {
        guard let view else { return nil }
        let rect = view.convert(view.bounds, to: host)
        return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    }
}

@MainActor
private final class DeckTopRecorder {
    var deckTop: CGFloat?
}

private struct DeckTopReader: NSViewRepresentable {
    let recorder: DeckTopRecorder

    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_: NSView, context: Context) {
        recorder.deckTop = context.environment.terminalDeckTop
    }
}

@MainActor
private final class DeckRecorder {
    var views: [Int: NSView] = [:]
    var proposals: [Int: [ProposedViewSize]] = [:]
    var creations = 0
}

private struct DeckFixture: View {
    let recorder: DeckRecorder
    let selected: Int

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 300)
            VStack(spacing: 0) {
                Color.clear.frame(height: 50)
                TerminalDeck {
                    ForEach(0..<96, id: \.self) { index in
                        ZStack {
                            DeckProbe(index: index, recorder: recorder)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Color.clear.allowsHitTesting(false)
                        }
                        .opacity(index == selected ? 1 : 0)
                        .allowsHitTesting(index == selected)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

private struct DeckProbe: NSViewRepresentable {
    let index: Int
    let recorder: DeckRecorder

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        recorder.views[index] = view
        recorder.creations += 1
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        recorder.proposals[index, default: []].append(proposal)
        return proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }
}

private final class SleptPaneSurface: TerminalSurface {
    let paneToken = ""
    let isRealized = true
    func teardown() {}
    func promoteToPrimaryPane() {}
}
