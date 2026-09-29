import Foundation

/// The argv for `agterm-open-path`, which resolves a clicked path and opens it in an overlay
/// (`LinkPolicy.LinkDisposition.openPath`). The path goes last, after `--`.
public enum OpenPathLaunch {
    public static let helperName = "agterm-open-path"

    /// `--cwd` is the clicked pane's directory. `--pane` is passed only for a split session's left or right
    /// pane; otherwise the overlay takes the session-wide slot.
    @MainActor
    public static func arguments(path: String, line: Int?, session: Session, pane: CommandContext.Pane,
                                 socket: String?) -> [String] {
        var args = ["--cwd", session.cwd(for: pane), "--target", session.id.uuidString]
        if let socket { args += ["--socket", socket] }
        if session.isSplit, pane != .scratch { args += ["--pane", pane.rawValue] }
        if let line { args += ["--line", String(line)] }
        return args + ["--", path]
    }
}
