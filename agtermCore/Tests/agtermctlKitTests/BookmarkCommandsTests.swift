import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

// Its own file rather than more cases in `CommandsTests.swift`, which sits at the 2000-line test cap.
struct BookmarkCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func markTargetsASession() throws {
        #expect(try request(["session", "mark", "--target", "9f3c"])
                == ControlRequest(cmd: .sessionMark, target: "9f3c"))
    }

    @Test func markDefaultsToActiveAndFoldsWindowIntoArgs() throws {
        #expect(try request(["session", "mark"]) == ControlRequest(cmd: .sessionMark, target: "active"))
        #expect(try request(["session", "mark", "--window", "w1"])
                == ControlRequest(cmd: .sessionMark, target: "active", args: ControlArgs(window: "w1")))
    }

    @Test func addWithPromptAndTurn() throws {
        let expected = ControlRequest(cmd: .sessionBookmarkAdd, target: "9f3c",
                                      args: ControlArgs(text: "fix the flaky test", turn: 4))
        #expect(try request(["session", "bookmark", "add", "fix the flaky test",
                             "--turn", "4", "--target", "9f3c"]) == expected)
    }

    @Test func addDefaultsToActiveCurrentTurnAndNoPrompt() throws {
        let expected = ControlRequest(cmd: .sessionBookmarkAdd, target: "active",
                                      args: ControlArgs(text: nil, turn: nil))
        #expect(try request(["session", "bookmark", "add"]) == expected)
    }

    @Test func listTargetsASession() throws {
        let expected = ControlRequest(cmd: .sessionBookmarkList, target: "9f3c",
                                      args: ControlArgs(all: nil))
        #expect(try request(["session", "bookmark", "list", "--target", "9f3c"]) == expected)
    }

    @Test func listAllSpansSessions() throws {
        let expected = ControlRequest(cmd: .sessionBookmarkList, target: "active",
                                      args: ControlArgs(all: true))
        #expect(try request(["session", "bookmark", "list", "--all"]) == expected)
    }

    @Test func goCarriesTheTurn() throws {
        let expected = ControlRequest(cmd: .sessionBookmarkGo, target: "9f3c",
                                      args: ControlArgs(turn: 7))
        #expect(try request(["session", "bookmark", "go", "--turn", "7", "--target", "9f3c"]) == expected)
    }

    @Test func goRequiresTurn() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "bookmark", "go"]) }
    }

    @Test func removeCarriesTheTurn() throws {
        let expected = ControlRequest(cmd: .sessionBookmarkRemove, target: "active",
                                      args: ControlArgs(turn: 2))
        #expect(try request(["session", "bookmark", "remove", "--turn", "2"]) == expected)
    }

    @Test func removeRequiresTurn() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "bookmark", "remove"]) }
    }

    @Test func windowSelectorFoldsIntoArgs() throws {
        let expected = ControlRequest(cmd: .sessionBookmarkGo, target: "active",
                                      args: ControlArgs(window: "w1", turn: 1))
        #expect(try request(["session", "bookmark", "go", "--turn", "1", "--window", "w1"]) == expected)
    }

    @Test func listFormatsOneRowPerBookmarkWithNeedleNameAndPrompt() {
        let rows = [
            ControlBookmarkNode(id: "b1", session: "s1", sessionName: "api work", turn: 3,
                                prompt: "fix the parser", created: 1_700_000_000, needle: "⟦3⟧"),
            ControlBookmarkNode(id: "b2", session: "s2", sessionName: nil, turn: 1,
                                prompt: "first turn", created: 1_700_000_060, needle: "⟦1⟧")
        ]
        #expect(SocketClient.formatBookmarks(rows) == """
        ⟦3⟧ api work: fix the parser
        ⟦1⟧ s2: first turn
        """)
        #expect(SocketClient.formatBookmarks([]) == "no bookmarks")
    }

    @Test func listJSONRoundTripsForTheFzfPipe() throws {
        let node = ControlBookmarkNode(id: "b1", session: "s1", sessionName: "work", turn: 3,
                                       prompt: "fix the parser", created: 1_700_000_000, needle: "⟦3⟧")
        let response = ControlResponse(ok: true, result: ControlResult(bookmarks: [node]))
        let line = SocketClient.formatResponse(response, json: true)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        #expect(decoded.result?.bookmarks == [node])
    }
}
