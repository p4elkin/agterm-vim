import AppKit
import OSLog
import agtermCore

private let logger = Logger(subsystem: "com.umputun.agterm", category: "GhosttySurfaceLinks")

/// LinkOpener carries out what `LinkPolicy.route` decides for a clicked terminal link. The app sets `mode`
/// and `overlay` once at launch; the defaults keep every link in the browser, which is also what a surface
/// gets before the control server exists.
@MainActor
struct LinkOpener {
    static var shared = LinkOpener()

    var mode: () -> LinkOpenMode = { .browser }
    /// overlay opens `url` as a browsing page over the session and says whether it did; false sends the
    /// link to the browser.
    var overlay: (URL, UUID) -> Bool = { _, _ in false }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// helper starts an agterm-agents link helper as (name, arguments, session) and says whether it started;
    /// a seam so a hosted test never runs the user's installed helpers.
    var helper: (String, [String], UUID) -> Bool = LinkOpener.launchHelper

    func follow(_ raw: String, from origin: LinkPolicy.ClickOrigin) {
        switch LinkPolicy.route(for: raw, mode: mode(), origin: origin) {
        case .browser(let url): open(url)
        case .overlay(let url, let session): if !overlay(url, session) { open(url) }
        case .reveal(let url): reveal(url)
        case .ignore: return
        }
    }

    nonisolated private static func launchHelper(_ name: String, _ arguments: [String], _ sessionID: UUID) -> Bool {
        let candidates = ["\(NSHomeDirectory())/.local/bin/\(name)", "/opt/homebrew/bin/\(name)"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            logger.warning("link clicked but \(name, privacy: .public) is not installed")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["AGTERM_SESSION_ID"] = sessionID.uuidString
        process.environment = environment
        do {
            try process.run()
            return true
        } catch {
            logger.warning("\(name, privacy: .public) failed to launch: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
