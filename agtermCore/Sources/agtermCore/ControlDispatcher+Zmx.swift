import Foundation

extension ControlDispatcher {
    /// `restore.mode` and the `zmx` group. Split out of `ControlDispatcher.swift` so that file stays inside
    /// the 1000-line limit, following `+Hud` and `+Pick`.
    func dispatchZmxCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .zmxNew:
            if let name = request.args?.name, name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
                return ControlResponse(ok: false, error: "zmx.new name must not contain control characters")
            }
            if let error = Session.nameLimitError(request.args?.name) { return ControlResponse(ok: false, error: error) }
            let workspace = request.args?.workspace?.trimmedOrNil
            let options = ControlZmxNewOptions(name: request.args?.name, command: request.args?.command, cwd: request.args?.cwd,
                                               workspace: workspace)
            guard let host = request.args?.host?.trimmedOrNil else {
                // a local `zmx new` creates no row, so there is nothing to place
                guard workspace == nil else { return ControlResponse(ok: false, error: "zmx.new --workspace needs a host") }
                return actions.createAttachableSession(options)
            }
            guard RemoteSession.isPlain(host), !host.hasPrefix("-") else { return ControlResponse(ok: false, error: "invalid host") }
            return await actions.createRemoteSession(host: host, options: options, window: request.args?.window?.trimmedOrNil)
        case .zmxTree:
            // no host is this app's own attachable sessions, which is also exactly what a `zmx tree HOST`
            // runs on the far side
            return await actions.remoteTree(host: request.args?.host?.trimmedOrNil)
        case .zmxAttach, .zmxAttachGroup:
            // above the `--beside` guard, whose refusal would otherwise hide that the two do not combine
            if let refusal = Self.parentRefusal(request) { return refusal }
            // the target names a row here, not the remote session, so a plain attach would look it up on the host
            guard request.args?.attach == nil else {
                return ControlResponse(ok: false, error: "zmx.attach --beside is for a headless origin")
            }
            guard let host = request.args?.host?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a host")
            }
            // no `active` default: the target names a session on ANOTHER machine, which nothing local
            // could resolve for the caller
            guard let session = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a remote session")
            }
            // the unresolved case names the id it could not find, so a control character here would reach
            // a terminal through that message
            guard RemoteSession.isPlain(session) else {
                return ControlResponse(ok: false, error: "invalid remote session")
            }
            // trimmed like the host, so a padded spelling is not an unknown transport; the two paths are
            // NOT trimmed, an empty one being the quoting bug `RemoteTransport.parse` exists to refuse
            let rawTransport = request.args?.transport?.trimmedOrNil
            let rawMoshServer = request.args?.moshServer
            let rawMosh = request.args?.mosh
            let transport: RemoteTransport
            do {
                transport = try RemoteTransport.parse(transport: rawTransport, moshServer: rawMoshServer,
                                                      mosh: rawMosh)
            } catch {
                return ControlResponse(ok: false,
                                       error: RemoteTransport.refusalMessage(transport: rawTransport,
                                                                             moshServer: rawMoshServer,
                                                                             mosh: rawMosh))
            }
            if let parent = request.args?.parent?.trimmedOrNil {
                return await actions.attachRemoteSession(host: host, session: session, parent: parent)
            }
            let window = request.args?.window?.trimmedOrNil
            if request.cmd == .zmxAttachGroup {
                // every member attaches over ssh, so a requested mosh is refused rather than quietly not used
                guard transport == .ssh else {
                    return ControlResponse(ok: false, error: ControlActionsUnsupported.message("zmx.attach.group --transport"))
                }
                return await actions.attachRemoteGroup(host: host, session: session, window: window)
            }
            return await actions.attachRemoteSession(host: host, session: session, window: window, transport: transport)
        case .zmxPresent:
            // no `active` default: a viewer names the session it attached, and a guess would stream another
            guard let session = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "zmx.present requires a session")
            }
            guard RemoteSession.isPlain(session) else {
                return ControlResponse(ok: false, error: "invalid session")
            }
            return actions.openPresentation(session: session)
        default:
            return dispatchLocalZmxCommand(request)
        }
    }

    private func dispatchLocalZmxCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .restoreMode:
            guard let raw = request.args?.mode else { return actions.readRestoreMode() }
            // parsed strictly, unlike `RestoreMode`'s lossy decoder: a typo must not silently select
            // `none`, the one mode whose next launch reaps every detached daemon
            guard let mode = RestoreMode(rawValue: raw) else {
                return ControlResponse(ok: false, error: "invalid restore mode: \(raw)")
            }
            return actions.setRestoreMode(mode)
        case .zmxList:
            return actions.listZmxDaemons()
        case .zmxPrune:
            return actions.pruneZmxDaemons()
        case .zmxKill:
            // no `active` or left-pane default: this destroys a backend process rather than a model object,
            // reaching claims no window shows and every client attached to the daemon
            guard let target = request.target, !target.isEmpty else {
                return ControlResponse(ok: false, error: "zmx.kill requires an explicit --target")
            }
            guard let rawPane = request.args?.pane, let pane = ZmxPaneRole(controlName: rawPane) else {
                return ControlResponse(ok: false, error: "zmx.kill requires --pane left|right")
            }
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "zmx.kill requires --force")
            }
            return actions.killZmxDaemon(target: target, window: request.args?.window, pane: pane)
        case .zmxScreen:
            // a daemon name, as `zmx list` prints it: the session resolver sees only open windows
            guard let name = request.args?.name?.trimmedOrNil, RemoteSession.isPlain(name) else {
                return ControlResponse(ok: false, error: "zmx.screen requires a daemon name")
            }
            switch parseBufferExtent(request.args) {
            case .rejected(let response): return response
            case .extent(let all, let lines):
                return actions.readZmxScreen(name: name, fullBuffer: all || lines != nil, lines: lines)
            }
        case .zmxReset:
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "zmx.reset requires --force")
            }
            return actions.resetLiveSessions()

        default:
            preconditionFailure("unexpected zmx command: \(request.cmd.rawValue)")
        }
    }

    /// The row follows its parent's window and transport, so a placement or transport beside `--parent` is refused
    /// rather than ignored. An unresolved parent is echoed in the server's error, hence `isPlain`.
    static func parentRefusal(_ request: ControlRequest) -> ControlResponse? {
        guard let args = request.args, let parent = args.parent else { return nil }
        guard request.cmd == .zmxAttach else {
            return ControlResponse(ok: false, error: "zmx.attach --parent attaches one session, not its companions")
        }
        guard args.attach == nil, args.window == nil, args.transport == nil, args.moshServer == nil, args.mosh == nil else {
            return ControlResponse(ok: false, error: "zmx.attach --parent takes the parent row's window and transport")
        }
        guard let trimmed = parent.trimmedOrNil, RemoteSession.isPlain(trimmed) else {
            return ControlResponse(ok: false, error: "invalid parent")
        }
        return nil
    }
}
