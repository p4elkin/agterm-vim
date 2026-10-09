import ArgumentParser
import Foundation
import agtermCore

extension Session {
    struct RebasedCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rebased", abstract: "Show a view or hide and show the held Rebased IDE (fork only).",
            subcommands: [Show.self, Toggle.self])

        struct Show: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Open a diff or file in this session's held Rebased overlay (fork only).")
            @Option(name: .long, help: "Range to show: A..B, A...B (from the merge base), or A (A..HEAD).") var diff: String?
            @Flag(name: .long, help: "With --diff, compare tracked working-tree changes against the base.") var workingTree = false
            @Option(name: .long, help: "Open FILE[:LINE] in the editor instead of a diff.") var file: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws {
                guard (diff != nil) != (file != nil) else { throw ValidationError("provide exactly one of --diff and --file") }
                if workingTree, diff == nil { throw ValidationError("--working-tree requires --diff") }
                if let diff, RebasedView(diff: diff, workingTree: workingTree) == nil {
                    throw ValidationError("invalid --diff range or working-tree head")
                }
                if let file, RebasedFileTarget(spec: file) == nil { throw ValidationError("invalid --file target") }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionRebasedShow, target: target.target,
                               args: options.withWindow(ControlArgs(diff: diff, workingTree: workingTree ? true : nil,
                                                                    file: try file.map(Overlay.absoluteFileTarget))))
            }
        }

        struct Toggle: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Hide or show the held Rebased IDE, or open one when none is held (fork only).")
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionRebasedToggle, target: target.target, args: options.withWindow())
            }
        }
    }
}
