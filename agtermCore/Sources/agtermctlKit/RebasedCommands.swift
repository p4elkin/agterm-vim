import ArgumentParser
import Foundation
import agtermCore

// MARK: - rebased (fork only)

struct Rebased: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage what Rebased keeps on this Mac.",
        subcommands: [Mirror.self]
    )

    struct Mirror: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List and prune the local clones Rebased opens remote projects from.",
            discussion: """
            Opening Rebased on a remote row fetches that host's repository into a mirror under the state \
            directory, beside the IDE's own per-project data. The only automatic removal is the prune that runs \
            when the IDE starts, by rebasedMirrorMaxAgeDays (14 by default, 0 for never).
            """,
            subcommands: [List.self, Prune.self]
        )

        struct List: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "List every mirror, when it was last opened, and its size.",
                discussion: """
                One row per mirror: host, source, days since last opened, size, and the clone's directory. \
                "in use" before the directory marks a mirror an overlay shows or the IDE has opened in this \
                run; a prune never removes one. It reads the disk without waiting for a running fetch, so a mirror that \
                fetch is creating can be missing or partly sized.
                """)
            @OptionGroup var options: BasicOptions

            func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .rebasedMirrorList) }
        }

        struct Prune: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove the mirrors not opened for DAYS days, with their IDE data.",
                discussion: """
                Without --older-than it uses rebasedMirrorMaxAgeDays, and refuses when that setting is 0. \
                A mirror in use is kept whatever its age. --dry-run reports what would go and removes nothing.

                It waits for a running fetch to finish first, which can take minutes on a large repository.
                """)
            @Option(name: .long, help: "Remove mirrors last opened at least DAYS days ago; 1 or more.")
            var olderThan: Int?

            @Flag(name: .long, help: "Report what would be removed and remove nothing.")
            var dryRun = false

            @OptionGroup var options: BasicOptions

            func validate() throws {
                if let olderThan, olderThan < 1 {
                    throw ValidationError("rebased.mirror.prune --older-than must be 1 or more")
                }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .rebasedMirrorPrune,
                               args: ControlArgs(olderThanDays: olderThan, dryRun: dryRun ? true : nil))
            }
        }
    }
}

extension SocketClient {
    /// A list carries `mirrors`; a prune carries `removed` and `kept`, each line led by what happened to it.
    static func formatRebasedMirrors(_ report: ControlRebasedMirrors, now: Date = Date()) -> String {
        if let mirrors = report.mirrors {
            guard !mirrors.isEmpty else { return "no mirrors" }
            return mirrors.map { mirrorRow($0, now: now, inUse: $0.inUse) }.joined(separator: "\n")
        }
        let removed = (report.removed ?? []).map { node in
            (report.dryRun == true ? "would remove  " : "removed  ") + mirrorRow(node, now: now, inUse: false)
        }
        let kept = (report.kept ?? []).map { node in
            "kept: \(node.error ?? "in use")  " + mirrorRow(node, now: now, inUse: false)
        }
        guard !removed.isEmpty || !kept.isEmpty else {
            return report.olderThanDays.map { "no mirrors older than \($0) days" } ?? "no mirrors"
        }
        return (removed + kept).joined(separator: "\n")
    }

    private static func mirrorRow(_ node: ControlRebasedMirrorNode, now: Date, inUse: Bool) -> String {
        let days = max(0, Int((now.timeIntervalSince1970 - node.lastOpened) / 86400))
        let age = days == 1 ? "1 day" : "\(days) days"
        let marker = inUse ? "in use  " : ""
        return "\(node.host)  \(node.source ?? "-")  \(age)  \(mirrorSize(node.bytes))  \(marker)\(node.directory)"
    }

    /// Decimal units spelled by hand: `ByteCountFormatter` follows the locale, and a row should not.
    private static func mirrorSize(_ bytes: Int?) -> String {
        guard let bytes else { return "-" }
        var value = Double(bytes)
        var unit = "B"
        for next in ["KB", "MB", "GB", "TB"] where value >= 1000 {
            value /= 1000
            unit = next
        }
        return unit != "B" && value < 10 ? String(format: "%.1f %@", value, unit) : "\(Int(value.rounded())) \(unit)"
    }
}

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
