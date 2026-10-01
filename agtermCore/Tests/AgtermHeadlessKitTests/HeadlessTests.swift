import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit

@MainActor
struct HeadlessTests {
    private func withHeadless(_ body: (Headless, HeadlessActions, FakeHeadlessStreams) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-headless-kit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = HeadlessConfig.fromEnvironment([
            "AGTERM_HEADLESS_STATE": directory.path,
            "AGTERM_HEADLESS_ZMX": directory.appendingPathComponent("unused-zmx").path,
        ])
        let streams = FakeHeadlessStreams()
        let headless = Headless(config: config, runner: FakeZmxRunner()) { _, _ in streams }
        try await body(headless, HeadlessActions(headless: headless, installDirectory: directory), streams)
    }

    @Test func presentationHandsTheConnectionToTheAdapter() async throws {
        try await withHeadless { headless, actions, streams in
            let window = try #require(headless.library.windows.first)
            let store = try #require(headless.library.store(for: window.id))
            let session = try #require(store.workspaces.first?.sessions.first)
            #expect(store.presentationHub === headless.hub)
            #expect(session.allPanesBackedByZmx)

            let response = await actions.serve(ControlRequest(cmd: .zmxPresent, target: session.id.uuidString), connection: 123)

            #expect(response == nil)
            #expect(streams.adoptedSessions == [session.id])
            #expect(streams.adoptedDescriptors == [123])
        }
    }

    @Test func unknownSessionDoesNotHandOffTheConnection() async throws {
        try await withHeadless { _, actions, streams in
            let target = UUID().uuidString

            let response = await actions.serve(ControlRequest(cmd: .zmxPresent, target: target), connection: 123)

            #expect(response == ControlResponse(ok: false, error: "no such session: \(target)"))
            #expect(streams.adoptedSessions.isEmpty)
        }
    }

    @Test func adapterFailureKeepsTheOrdinaryResponse() async throws {
        try await withHeadless { headless, actions, streams in
            let window = try #require(headless.library.windows.first)
            let store = try #require(headless.library.store(for: window.id))
            let session = try #require(store.workspaces.first?.sessions.first)
            streams.response = ControlResponse(ok: false, error: "internal")

            let response = await actions.serve(ControlRequest(cmd: .zmxPresent, target: session.id.uuidString), connection: 123)

            #expect(response == streams.response)
        }
    }

    @Test func anOrdinaryCommandKeepsTheConnection() async throws {
        try await withHeadless { _, actions, streams in
            let response = await actions.serve(ControlRequest(cmd: .windowList), connection: 123)

            #expect(response?.ok == true)
            #expect(streams.adoptedSessions.isEmpty)
        }
    }
}

@MainActor
private final class FakeHeadlessStreams: HeadlessStreams {
    var adoptedSessions: [UUID] = []
    var adoptedDescriptors: [Int32] = []
    var closedSessions: [UUID] = []
    var response: ControlResponse?

    func adopt(session: UUID, fd: Int32) -> ControlResponse? {
        adoptedSessions.append(session)
        adoptedDescriptors.append(fd)
        return response
    }

    func closeStreams(session: UUID) { closedSessions.append(session) }
}
