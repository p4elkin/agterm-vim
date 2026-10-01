import Foundation
import Testing
import agtermCore
import AgtermHeadlessKit

@MainActor
struct HeadlessCoverageTests {
    @Test func requestListCoversEveryCommandOnce() throws {
        let listed = HeadlessRequests.all.map(\.cmd.rawValue)
        let declared = try Self.declaredCommands()

        #expect(Set(listed).count == listed.count)
        #expect(listed.count == declared.count)
        #expect(Set(listed) == Set(declared))
    }

    @Test(arguments: HeadlessRequests.all)
    func commandsAnswerAccordingToTheCatalog(_ request: ControlRequest) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        if request.cmd == .sessionSwap { _ = try fixture.split() }
        if request.cmd == .sessionHudUpdate || request.cmd == .sessionHudClose {
            #expect(fixture.actions.openHud(fixture.session.id.uuidString, window: nil, spec: HudSpec(message: "existing")).ok)
        }
        var prepared = bound(request, to: fixture)
        if request.cmd == .askResult || request.cmd == .askCancel {
            let opened = try await fixture.dispatch(.askOpen) {
                $0.title = "existing"; $0.buttons = [ControlAskButton(id: "ok", label: "OK")]
            }
            let id = try #require(opened.result?.id)
            prepared = ControlRequest(cmd: request.cmd, target: id, args: request.args)
        }
        let response = await fixture.actions.respond(to: prepared)

        switch HeadlessCatalog.support(for: request.cmd) {
        case .served: #expect(response.ok)
        case .refused(let text): #expect(response == ControlResponse(ok: false, error: text))
        }
    }

    @Test(arguments: HeadlessRequests.all)
    func dispatcherAnswersEverythingButTheAppearanceSeam(_ request: ControlRequest) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        if request.cmd == .sessionSwap { _ = try fixture.split() }
        let response = await ControlDispatcher(actions: fixture.actions).dispatch(bound(request, to: fixture))

        #expect((response == nil) == (request.cmd == .debugAppearance))
    }

    @Test func aSearchForABookmarkTokenIsStillASearch() async throws {
        let request = HeadlessRequests.request(.sessionSearch, target: HeadlessRequests.target) { $0.text = TurnMark.needle(for: 1) }

        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        #expect(await fixture.actions.respond(to: request) == refusal(.sessionSearch))
    }

    @Test func anInvalidBookmarkTurnKeepsTheDispatcherError() async throws {
        let request = HeadlessRequests.request(.sessionBookmarkGo, target: HeadlessRequests.target) { $0.turn = 0 }
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        if request.cmd == .sessionSwap { _ = try fixture.split() }
        let response = await fixture.actions.respond(to: bound(request, to: fixture))

        #expect(response.ok == false)
        #expect(response != refusal(.sessionBookmarkGo))
        #expect(response != refusal(.sessionSearch))
    }

    private func bound(_ request: ControlRequest, to fixture: HeadlessActionFixture) -> ControlRequest {
        ControlRequest(cmd: request.cmd,
                       target: request.target == HeadlessRequests.target ? fixture.session.id.uuidString : request.target,
                       args: request.args)
    }

    private func refusal(_ command: Command) -> ControlResponse? {
        guard case .refused(let text) = HeadlessCatalog.support(for: command) else { return nil }
        return ControlResponse(ok: false, error: text)
    }

    /// `Command` is not `CaseIterable`, so its cases are read from the declaration: one `case` per line.
    private static func declaredCommands() throws -> [String] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/agtermCore/ControlProtocol.swift")
        let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("public enum Command:") })
        let end = try #require(lines[start...].firstIndex { $0 == "}" })
        return lines[start..<end].compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { return nil }
            let parts = trimmed.dropFirst("case ".count).components(separatedBy: " = ")
            return parts.count == 2 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : parts[0]
        }
    }
}
