import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
@Suite(.serialized)
struct HeadlessAskTests {
    static let buttons = [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")]

    final class Sink: PresentationSink {
        var bodies: [PresentationFrame.Body] = []
        private weak var hub: PresentationHub?
        private var subscriber: PresentationHub.SubscriberID?
        private var generation = 0

        init(_ fixture: HeadlessActionFixture, mode: PresentationMode = .presenter) throws {
            hub = fixture.headless.hub
            subscriber = try fixture.headless.hub.subscribe(session: fixture.session.id,
                hello: PresentationHello(version: 1, kinds: [], mode: mode), sink: self) {
                fixture.store.presentationSnapshot(forSession: fixture.session.id)
            }
        }

        func offer(_ frame: PresentationFrame) -> Bool {
            generation = frame.gen
            bodies.append(frame.body)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        func send(_ body: PresentationFrame.Body) {
            guard let subscriber else { return }
            hub?.receive(PresentationFrame(gen: generation, rev: 0, body: body), from: subscriber)
        }

        func disconnect() {
            if let subscriber { hub?.unsubscribe(subscriber) }
            subscriber = nil
        }

        var requests: [PresentationAsk] {
            bodies.compactMap { if case .askRequest(let ask) = $0 { ask } else { nil } }
        }

        var dismissals: [PresentationAskRef] {
            bodies.compactMap { if case .askDismiss(let ref) = $0 { ref } else { nil } }
        }
    }

    private func open(_ fixture: HeadlessActionFixture,
                      _ edit: (inout ControlArgs) -> Void = { _ in }) async throws -> String {
        ZmxLeadBook.shared.forget(pane: fixture.session.paneIdentity)
        if let split = fixture.session.splitPaneIdentity { ZmxLeadBook.shared.forget(pane: split) }
        let response = try await fixture.dispatch(.askOpen) {
            $0.title = "deploy?"; $0.buttons = Self.buttons; edit(&$0)
        }
        #expect(response.ok)
        return try #require(response.result?.id)
    }

    private func result(_ fixture: HeadlessActionFixture, id: String) async throws -> ControlAskResult {
        let response = try await fixture.dispatch(.askResult, target: id)
        #expect(response.ok)
        return try #require(response.result?.ask)
    }

    @Test func aPresenterReceivesTheAskAloneWithAnEmptyLeadBook() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Sink(fixture)
        let mirror = try Sink(fixture, mode: .mirror)
        presenter.send(.presenterAcquire)

        let id = try await open(fixture)

        #expect(presenter.requests.map(\.id) == [id])
        #expect(mirror.requests.isEmpty)
        #expect(try await result(fixture, id: id).result == .pending)
        #expect(fixture.session.askPresentedRemotely)
    }

    @Test func anAskWithoutAPresenterWaitsInTheSessionSlot() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let mirror = try Sink(fixture, mode: .mirror)
        let count = mirror.bodies.count

        let id = try await open(fixture)

        #expect(fixture.session.askPending?.id == id)
        #expect(!fixture.session.askPresentedRemotely)
        #expect(try await result(fixture, id: id).result == .pending)
        #expect(mirror.bodies.count == count)
    }

    @Test func aLaterGrantOffersAWaitingAskWithItsSplitPane() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let pane = try fixture.split()
        fixture.store.setSplitVisibility(fixture.session.id, shown: false)
        let viewer = try Sink(fixture)
        let id = try await open(fixture) { $0.pane = "right" }
        #expect(viewer.requests.isEmpty)

        viewer.send(.presenterAcquire)

        let request = try #require(viewer.requests.last)
        #expect(request.id == id)
        #expect(request.pane == .identity(pane))
        #expect(fixture.session.askPaneIdentity == pane)
        #expect(fixture.session.askPresentedRemotely)
    }

    @Test func aPresenterAnswerCompletesTheCliPollingResult() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Sink(fixture)
        presenter.send(.presenterAcquire)
        let id = try await open(fixture)
        #expect(try await result(fixture, id: id).result == .pending)
        let request = try #require(presenter.requests.last)

        presenter.send(.askResolve(PresentationAskAnswer(id: id, owner: request.owner, button: "no")))

        #expect(try await result(fixture, id: id) == ControlAskResult(result: .answered, id: "no", label: "No", index: 1))
        #expect(fixture.session.askPending == nil)
    }

    @Test func losingTheLastPresenterWaitsAndANewGrantUsesANewOwner() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let first = try Sink(fixture)
        first.send(.presenterAcquire)
        let id = try await open(fixture)
        let oldOwner = try #require(first.requests.last?.owner)

        first.disconnect()

        #expect(!fixture.session.askPresentedRemotely)
        #expect(try await result(fixture, id: id).result == .pending)
        let next = try Sink(fixture)
        next.send(.presenterAcquire)
        let request = try #require(next.requests.last)
        #expect(request.id == id)
        #expect(request.owner > oldOwner)
        next.send(.askResolve(PresentationAskAnswer(id: id, owner: oldOwner, button: "yes")))
        #expect(try await result(fixture, id: id).result == .pending)
        next.send(.askResolve(PresentationAskAnswer(id: id, owner: request.owner, button: "yes")))
        #expect(try await result(fixture, id: id).id == "yes")
    }

    @Test func aHandOffReoffersTheAskToTheConnectedReplacement() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let first = try Sink(fixture)
        first.send(.presenterAcquire)
        let next = try Sink(fixture)
        next.send(.presenterAcquire)
        let id = try await open(fixture)
        let owner = try #require(first.requests.last?.owner)

        first.disconnect()

        #expect(next.requests.last?.id == id)
        #expect(try #require(next.requests.last?.owner) > owner)
        #expect(fixture.session.askPresentedRemotely)
        #expect(try await result(fixture, id: id).result == .pending)
    }

    @Test(arguments: [false, true])
    func cancelEndsAWaitingOrPresentedAsk(presented: Bool) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let viewer = try Sink(fixture)
        if presented { viewer.send(.presenterAcquire) }
        let id = try await open(fixture)

        #expect(try await fixture.dispatch(.askCancel, target: id).ok)

        #expect(try await result(fixture, id: id).result == .cancelled)
        #expect(fixture.session.askPending == nil)
        #expect(viewer.dismissals.map(\.id) == (presented ? [id] : []))
        #expect(try await fixture.dispatch(.askCancel, target: id).ok)
    }

    @Test(arguments: [false, true])
    func sessionCloseEndsAWaitingOrPresentedAsk(presented: Bool) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let viewer = try Sink(fixture)
        if presented { viewer.send(.presenterAcquire) }
        let id = try await open(fixture)

        #expect(try await fixture.dispatch(.sessionClose).ok)

        #expect(try await result(fixture, id: id).result == .cancelled)
        #expect(viewer.dismissals.map(\.id) == (presented ? [id] : []))
    }

    @Test func aConfirmedRejectionCancelsWithPresentationLost() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let viewer = try Sink(fixture)
        viewer.send(.presenterAcquire)
        let id = try await open(fixture)
        let request = try #require(viewer.requests.last)

        viewer.send(.askRejected(PresentationAskRef(id: id, owner: request.owner)))

        #expect(try await result(fixture, id: id) == ControlAskResult(result: .cancelled, reason: ControlAskResult.presentationLost))
    }

    @Test func anOldRejectionOrAMirrorsAnswerChangesNothing() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let presenter = try Sink(fixture)
        presenter.send(.presenterAcquire)
        let mirror = try Sink(fixture, mode: .mirror)
        let id = try await open(fixture)
        let owner = try #require(presenter.requests.last?.owner)

        presenter.send(.askRejected(PresentationAskRef(id: "old-ask", owner: owner)))
        presenter.send(.askRejected(PresentationAskRef(id: id, owner: owner + 1)))
        mirror.send(.askResolve(PresentationAskAnswer(id: id, owner: owner, button: "yes")))

        #expect(try await result(fixture, id: id).result == .pending)
    }

    @Test func stablePaneTokensOverrideRolesWithoutAVisibilityCheck() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let pane = try fixture.split()
        fixture.store.setSplitVisibility(fixture.session.id, shown: false)
        let viewer = try Sink(fixture)
        viewer.send(.presenterAcquire)

        _ = try await open(fixture) { $0.pane = "left"; $0.paneID = pane.uuidString }

        #expect(viewer.requests.last?.pane == .identity(pane))
    }

    @Test func closingTheTargetSplitEndsItsWaitingAsk() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.split()
        let id = try await open(fixture) { $0.pane = "right" }

        #expect(try await fixture.dispatch(.sessionSplitClose).ok)

        #expect(try await result(fixture, id: id).result == .cancelled)
    }

    @Test func guiAsksAndPicksAreRefusedByName() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let response = try await fixture.dispatch(.askOpen) {
            $0.title = "gui"; $0.buttons = Self.buttons; $0.style = "gui"
        }
        #expect(response.error == "gui asks are not available on a headless origin; use --style terminal")
        #expect(fixture.session.askPending == nil)
        let pick = try await fixture.dispatch(.pickOpen) { $0.items = [ControlPickItem(id: "one", label: "One")] }
        #expect(!pick.ok)
        #expect(pick.error?.contains("pick.open") == true)
    }

    @Test func invalidPlacementAndAnOccupiedAskSlotAreRefused() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let invalid = try await fixture.dispatch(.askOpen) { $0.title = "bad"; $0.buttons = Self.buttons; $0.pane = "right" }
        #expect(!invalid.ok)
        #expect(fixture.session.askPending == nil)
        let id = try await open(fixture)
        let occupied = try await fixture.dispatch(.askOpen) { $0.title = "second"; $0.buttons = Self.buttons }
        #expect(occupied.error == "ask already pending")
        #expect(fixture.session.askPending?.id == id)
    }

    @Test func resultAndCancelValidateTheAskIdAndWindow() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let id = try await open(fixture)
        let window = try #require(fixture.headless.library.windowID(for: fixture.store))
        #expect(try await fixture.dispatch(.askResult, target: id) { $0.window = window.uuidString }.ok)
        #expect(try await fixture.dispatch(.askResult, target: id) { $0.window = UUID().uuidString }.ok == false)
        #expect(try await fixture.dispatch(.askCancel, target: "missing").ok == false)
        #expect(try await fixture.dispatch(.askResult, target: "missing").error == "unknown ask: missing")
    }
    @Test func aTakeDismissesTheOldAskAndReoffersItsPaneWithANewOwner() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let pane = try fixture.split()
        let first = try Sink(fixture), next = try Sink(fixture)
        first.send(.presenterAcquire)
        let id = try await open(fixture) { $0.pane = "right" }
        let old = try #require(first.requests.last)
        next.send(.presenterTake)
        let new = try #require(next.requests.last)
        #expect(first.dismissals == [PresentationAskRef(id: id, owner: old.owner)])
        #expect(first.bodies.last == .presenterRefused)
        #expect(next.bodies.suffix(2).first == .presenterGranted)
        #expect(new.id == id)
        #expect(new.pane == .identity(pane))
        #expect(new.owner == old.owner + 1)
        #expect(fixture.session.askPresentedRemotely)
        first.send(.askResolve(PresentationAskAnswer(id: id, owner: old.owner, button: "yes")))
        next.send(.askResolve(PresentationAskAnswer(id: id, owner: old.owner, button: "yes")))
        #expect(try await result(fixture, id: id).result == .pending)
        next.send(.askResolve(PresentationAskAnswer(id: id, owner: new.owner, button: "no")))
        #expect(try await result(fixture, id: id).id == "no")
    }

}
