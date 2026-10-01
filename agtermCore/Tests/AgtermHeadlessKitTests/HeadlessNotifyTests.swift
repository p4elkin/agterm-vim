import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

extension HeadlessActionsTests {
    @Test func notifyReachesAnAttachedViewer() async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let sink = try NotifySink(fixture)

        #expect(try await fixture.dispatch(.notify) { $0.title = "build"; $0.body = "finished" }.ok)

        #expect(sink.notes.map(\.body) == ["finished"])
    }

    @Test(arguments: ["active", nil] as [String?])
    func anActiveTargetNamesTheFix(_ target: String?) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let request = HeadlessRequests.request(.notify, target: target) { $0.body = "b" }

        let response = try #require(await ControlDispatcher(actions: fixture.actions).dispatch(request))

        #expect(response.error == "a headless origin has no active session; pass --target \"$AGTERM_SESSION_ID\"")
    }
}

@MainActor
private final class NotifySink: PresentationSink {
    var notes: [PresentationNotify] = []

    init(_ fixture: HeadlessActionFixture) throws {
        try fixture.headless.hub.subscribe(session: fixture.session.id,
                                          hello: PresentationHello(version: 1, kinds: PresentationHub.supportedKinds, mode: .mirror),
                                          sink: self) {
            fixture.store.presentationSnapshot(forSession: fixture.session.id)
        }
    }

    func offer(_ frame: PresentationFrame) -> Bool {
        if case .notify(let note) = frame.body { notes.append(note) }
        return true
    }

    func close(_ reason: PresentationHub.CloseReason) {}
}
