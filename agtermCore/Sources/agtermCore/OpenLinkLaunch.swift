import Foundation

/// The argv for `agterm-open-link`, which shows a clicked web link or forge ref as a Jira, merge request or other
/// forge view, or hands it to the browser. Of the web schemes only `http`/`https` go there; `mailto` and `ftp`
/// stay with the system opener. A forge ref (`LinkPolicy.LinkDisposition.ref`) always goes there.
public enum OpenLinkLaunch {
    public static let helperName = "agterm-open-link"

    public static func handles(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// `--pane` is passed only for a split session's left or right pane, as in `OpenPathLaunch`.
    @MainActor
    public static func arguments(url: URL, session: Session, pane: CommandContext.Pane, socket: String?) -> [String] {
        var args = ["--target", session.id.uuidString]
        if let socket { args += ["--socket", socket] }
        if session.isSplit, pane != .scratch { args += ["--pane", pane.rawValue] }
        return args + ["--", url.absoluteString]
    }

    /// `--cwd` is the clicked pane's directory: a short ref's repository, and a cross-project ref's forge host.
    @MainActor
    public static func arguments(ref: String, session: Session, pane: CommandContext.Pane, socket: String?) -> [String] {
        var args = ["--cwd", session.cwd(for: pane), "--target", session.id.uuidString]
        if let socket { args += ["--socket", socket] }
        if session.isSplit, pane != .scratch { args += ["--pane", pane.rawValue] }
        return args + ["--", LinkPolicy.refScheme + ":" + ref]
    }
}
