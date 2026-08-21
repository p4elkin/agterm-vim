import ArgumentParser
import Foundation
import agtermCore

// `session bookmark` (fork only): bookmark marked turns and jump back to them. See `TurnMark` for the
// mark/needle contract and `.claude/rules/control-api.md` for why no upstream surface documents these.
extension Session {
    /// `session mark` (fork only): what the installed `UserPromptSubmit` hook calls at each turn start.
    struct Mark: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Advance the session's turn counter and write the visible turn mark (fork only).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions
        /// The calling surface's stable spawn token (`AGTERM_PANE_ID`). The mark must land in the pane the
        /// AGENT runs in, not the session's primary one — an agent in a split would otherwise write its
        /// marks over the other pane's output, and `bookmark go` would search a pane that has none.
        @Option(name: .customLong("pane-id"), help: "Surface token of the pane to mark (AGTERM_PANE_ID).")
        var paneID: String?

        func makeRequest() throws -> ControlRequest {
            // `map`, not a bare `ControlArgs(paneID:)`: an all-nil args object is not the same wire shape as
            // no args at all, and the hook omits the token whenever the app did not inject one.
            ControlRequest(cmd: .sessionMark, target: target.target,
                           args: options.withWindow(paneID.map { ControlArgs(paneID: $0) }))
        }

        // the human answer is the bare turn number, scriptable like `surface.cursor`'s column; the
        // shared formatter would read `result.count` as a diagnostic count.
        func run() throws {
            let client = SocketClient(path: options.socketPath())
            let response = try client.send(try makeRequest())
            if !options.json, response.ok, let turn = response.result?.count {
                print(turn)
                return
            }
            try printAndCheck(response)
        }
    }

    // named like `FlagCommand`: a bare `Bookmark` would collide with the agtermCore model type.
    struct BookmarkCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bookmark",
            abstract: "Bookmark marked conversation turns (fork only).",
            subcommands: [Add.self, List.self, Go.self, Remove.self]
        )

        struct Add: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Bookmark a turn: the session's current turn, or --turn. Same turn twice updates the entry.")
            @Argument(help: "The prompt text to store with the bookmark (shown when the mark leaves scrollback).")
            var prompt: String?
            @Option(name: .long, help: "Turn number to bookmark (defaults to the session's current turn).")
            var turn: Int?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBookmarkAdd, target: target.target,
                               args: options.withWindow(ControlArgs(text: prompt, turn: turn)))
            }
        }

        struct List: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "List bookmarks as JSON rows for a picker: the target session's, or --all sessions.")
            @Flag(name: .long, help: "List every session's bookmarks (ignores --target).")
            var all = false
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBookmarkList, target: target.target,
                               args: options.withWindow(ControlArgs(all: all ? true : nil)))
            }
        }

        struct Go: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Jump the pane back to a bookmarked turn's mark (a session search; 0 matches = mark gone).")
            @Option(name: .long, help: "Turn number of the bookmark to jump to.")
            var turn: Int
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBookmarkGo, target: target.target,
                               args: options.withWindow(ControlArgs(turn: turn)))
            }
        }

        struct Remove: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Drop the bookmark for a turn.")
            @Option(name: .long, help: "Turn number of the bookmark to drop.")
            var turn: Int
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBookmarkRemove, target: target.target,
                               args: options.withWindow(ControlArgs(turn: turn)))
            }
        }
    }
}
