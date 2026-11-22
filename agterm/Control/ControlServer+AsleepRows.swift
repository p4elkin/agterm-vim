import Foundation
import agtermCore

/// A control command on a row asleep here (`PtyWake` decides which pane it addresses): one that drives the pane's live
/// surface wakes the row with `pty` and runs once that pane reports its first lead, and `session.text` reads the pane's
/// screen on the origin and leaves the row asleep.
extension ControlServer {
    /// ptyWakeTimeout covers a pooled pane line's 15 s wait for its master, then the attach and its first report.
    static let ptyWakeTimeout: TimeInterval = 20
    static let ptyWakePoll: TimeInterval = 0.05
    static let originScreenDeadline: TimeInterval = 10

    /// asleepRowResponse answers `request` on an asleep row: the origin's screen or a failed wake; nil runs it as usual.
    /// After a wake `request` targets the row it woke and its window, since a selection can move during the wait.
    func asleepRowResponse(_ request: inout ControlRequest) async -> ControlResponse? {
        guard request.cmd == .sessionText || PtyWake.commands.contains(request.cmd),
              let (store, session, surface) = asleepRow(request),
              let pane = PtyWake.pane(of: request, on: session, surface: surface) else { return nil }
        if request.cmd == .sessionText { return await originScreenText(request.args, session: session, pane: pane) }
        if let refusal = await wakeForPty(request.cmd, store: store, session: session, pane: pane) { return refusal }
        request.target = surface.map { TerminalSurfaceID(sessionID: session.id, surface: $0).rawValue } ?? session.id.uuidString
        if request.args?.window != nil { request.args?.window = library.windowID(for: store)?.uuidString }
        return nil
    }

    private func asleepRow(_ request: ControlRequest) -> (AppStore, Session, TerminalZoomSurface?)? {
        let window = request.args?.window
        if request.cmd == .surfaceCursor, request.args?.paneID?.isEmpty != false {
            guard let (store, target) = cursorTarget(request.target, window: window), case .session(let id, let kind) = target,
                  let session = store.session(withID: id), session.asleep else { return nil }
            return (store, session, kind)
        }
        guard case .success(let (store, id)) = resolver.resolveSessionTarget(request.target, window: window),
              let session = store.session(withID: id), session.asleep else { return nil }
        return (store, session, nil)
    }

    /// cursorTarget resolves `surface.cursor`'s surface target as `readSurfaceCursor` does.
    private func cursorTarget(_ target: String?, window: String?) -> (AppStore, TerminalZoomTarget)? {
        let raw = trimmed(target) ?? "active"
        if raw == "active" {
            guard case .success(let (windowID, store)) = resolveOpenWindow(window),
                  let target = TerminalZoomRegistry.shared.controller(for: windowID)?.target
                    ?? TerminalZoomController.resolveTarget(store: store) else { return nil }
            return (store, target)
        }
        guard let id = TerminalSurfaceID(rawValue: raw), case .success(let (_, store)) = resolveSurfaceOwner(id, window: window) else {
            return nil
        }
        return (store, .session(id.sessionID, id.surface))
    }

    /// wakeForPty wakes the row and waits for `pane`'s first lead report, whatever its role: the command's own arm then
    /// answers for a pane another Mac leads. Nil once it reported.
    private func wakeForPty(_ command: Command, store: AppStore, session: Session, pane: PtyWake.Pane) async -> ControlResponse? {
        let refusal = { (reason: String) in
            ControlResponse(ok: false, error: "\(command.rawValue): the row was asleep and \(reason); the command did not run")
        }
        let shown = library.windowID(for: store).map { onScreenRows(inWindow: $0, store: store).contains(session.id) } ?? false
        guard store.wakeRemoteRow(session.id, reason: .pty, onScreen: shown, now: hudClock()) else {
            return refusal("could not be woken")
        }
        let deadline = hudClock().addingTimeInterval(Self.ptyWakeTimeout)
        while ZmxLeadBook.shared.role(pane: pane.identity) == nil {
            // no attach began (an ended row) or a later sleep forgot it: no report is coming
            guard ZmxLeadBook.shared.states[pane.identity] != nil else {
                return refusal("its \(pane.role.rawValue) pane has nothing to attach")
            }
            guard hudClock() < deadline else {
                return refusal("its \(pane.role.rawValue) pane did not attach within \(Int(Self.ptyWakeTimeout)) s")
            }
            await ptyWakeSleep(Self.ptyWakePoll)
        }
        return nil
    }

    /// originScreenText is `session.text` read from the pane's daemon on its origin, as `zmx.screen` reads one here.
    private func originScreenText(_ args: ControlArgs?, session: Session, pane: PtyWake.Pane) async -> ControlResponse? {
        let all = args?.all ?? false, lines = args?.lines
        // the arm's own refusals of the extent
        if all && lines != nil || lines.map({ $0 <= 0 }) == true { return nil }
        let binding = session.remotePresentation?.binding
        guard let origin = binding?.origin, let daemon = binding?.daemon(forLocalPane: pane.identity),
              let argv = try? RemoteSession.screenCommand(host: origin.host, endpoint: origin.endpoint, daemon: daemon,
                                                          all: all || lines != nil) else {
            return ControlResponse(ok: false, error: "session.text: the row is asleep and its \(pane.role.rawValue) pane "
                                       + "has no screen to read on its host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.originScreenDeadline)
        guard result.status == 0, let screen = ZmxScreen(output: result.stdout) else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ControlResponse(ok: false, error: "session.text: the row is asleep and its screen on \(origin.host) "
                                       + "could not be read" + (reason.isEmpty ? "" : ": \(reason)"))
        }
        var response = ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
        response.result?.pane = pane.role.rawValue
        return response
    }
}
