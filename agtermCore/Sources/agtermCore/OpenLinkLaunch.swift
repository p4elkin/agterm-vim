import Foundation

/// The argv for `agterm-open-link`, which shows a clicked web link as a Jira or merge request view or hands it
/// to the browser. Only `http`/`https` go there; `mailto` and `ftp` stay with the system opener.
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
}
