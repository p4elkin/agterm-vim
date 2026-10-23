import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct TransferFlagsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
    }

    @Test func workspaceMoveSendsToWindowAndWindowName() throws {
        let expected = ControlRequest(cmd: .workspaceMove, target: "w1",
                                      args: ControlArgs(window: "src", toWindow: "new", windowName: "build"))
        #expect(try request(["workspace", "move", "--to-window", "new", "--window-name", "build",
                             "--target", "w1", "--window", "src"]) == expected)
    }

    @Test func workspaceMoveStillReordersWithTo() throws {
        #expect(try request(["workspace", "move", "--to", "top"])
            == ControlRequest(cmd: .workspaceMove, target: "active", args: ControlArgs(to: "top")))
    }

    @Test func workspaceMoveNeedsExactlyOneDestination() {
        #expect(validationMessage(["workspace", "move"]) == "provide --to or --to-window")
        #expect(validationMessage(["workspace", "move", "--to", "up", "--to-window", "new"])
            == "use either --to or --to-window, not both")
    }

    @Test func sessionMoveSendsToWindowWithTheBatchAndAWorkspace() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1",
                                      args: ControlArgs(targets: ["s1", "s2"], workspace: "ws2", toWindow: "work"))
        #expect(try request(["session", "move", "ws2", "--to-window", "work", "--target", "s1", "--target", "s2"]) == expected)
    }

    @Test func sessionMoveSendsToWindowAloneWithWorkspaceAndWindowNames() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "active",
                                      args: ControlArgs(workspaceName: "logs", toWindow: "new", windowName: "ops"))
        #expect(try request(["session", "move", "--to-window", "new", "--workspace-name", "logs", "--window-name", "ops"])
            == expected)
        #expect(try request(["session", "move", "--to-window", "work"])
            == ControlRequest(cmd: .sessionMove, target: "active", args: ControlArgs(toWindow: "work")))
    }

    @Test(arguments: [["--to", "up"], ["--after", "s2"], ["--before", "s2"]])
    func sessionMoveRejectsToWindowWithAPlacement(_ placement: [String]) {
        #expect(validationMessage(["session", "move", "--to-window", "new"] + placement)
            == "--to-window cannot be combined with --to, --after or --before")
    }

    @Test func workspaceNameNeedsToWindowAndNoWorkspaceArgument() {
        #expect(validationMessage(["session", "move", "--workspace-name", "logs"]) == "--workspace-name needs --to-window")
        #expect(validationMessage(["session", "move", "ws2", "--to-window", "new", "--workspace-name", "logs"])
            == "provide a destination workspace or --workspace-name, not both")
    }

    @Test(arguments: [["workspace", "move"], ["session", "move"]])
    func windowNameNeedsToWindowNew(_ command: [String]) {
        #expect(validationMessage(command + ["--to-window", "work", "--window-name", "ops"]) == "--window-name needs --to-window new")
        #expect(validationMessage(command + ["--to", "up", "--window-name", "ops"]) == "--window-name needs --to-window new")
    }

    @Test func existingSessionMoveFormsStillParse() throws {
        #expect(try request(["session", "move", "ws2", "--target", "s1"])
            == ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(workspace: "ws2")))
        #expect(try request(["session", "move", "--after", "s2"])
            == ControlRequest(cmd: .sessionMove, target: "active", args: ControlArgs(after: "s2")))
    }

    @Test func helpListsTheNewFlags() {
        let workspace = Workspace.Move.helpMessage(columns: 200)
        let session = Session.Move.helpMessage(columns: 200)

        #expect(workspace.contains("--to-window") && workspace.contains("--window-name"))
        #expect(session.contains("--to-window") && session.contains("--window-name") && session.contains("--workspace-name"))
    }
}
