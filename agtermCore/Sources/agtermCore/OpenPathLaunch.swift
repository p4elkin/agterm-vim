import Foundation

/// The argv for `agterm-open-path`, which resolves a clicked path and opens it in an overlay
/// (`LinkPolicy.LinkDisposition.openPath`). The path goes last, after `--`.
public enum OpenPathLaunch {
    public static let helperName = "agterm-open-path"

    /// `--pane` is passed only for a split session's left or right pane; otherwise the overlay takes the
    /// session-wide slot.
    public static func arguments(path: String, line: Int?, cwd: String, sessionID: UUID,
                                 pane: CommandContext.Pane, isSplit: Bool, socket: String?) -> [String] {
        var args = ["--cwd", cwd, "--target", sessionID.uuidString]
        if let socket { args += ["--socket", socket] }
        if isSplit, pane != .scratch { args += ["--pane", pane.rawValue] }
        if let line { args += ["--line", String(line)] }
        return args + ["--", path]
    }
}
