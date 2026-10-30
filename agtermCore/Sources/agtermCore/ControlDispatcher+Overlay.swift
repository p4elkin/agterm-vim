import Foundation

extension ControlDispatcher {
    /// Validates the overlay commands before the host resolves the session or touches its slots.
    func dispatchSessionOverlayCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionOverlayOpen:
            let rebasedView: RebasedView?
            switch Self.parseRebasedView(request.args) {
            case .rejected(let response): return response
            case .view(let view): rebasedView = view
            }
            let command = request.args?.command ?? ""
            let page: HtmlSource?
            let rebased: Bool
            switch Self.overlayContent(command: command, args: request.args) {
            case .rejected(let response): return response
            case .program: page = nil; rebased = false
            case .page(let source): page = source; rebased = false
            case .rebased: page = nil; rebased = true
            }
            let rebasedDiff: RebasedDiff?
            if case .diff(let diff, _) = rebasedView { rebasedDiff = diff } else { rebasedDiff = nil }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            let pane: OverlayPane?
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let parsed): pane = parsed
            }
            if pane != nil, request.args?.sizePercent != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
            }
            let points = OverlayPointSize(width: request.args?.width, height: request.args?.height)
            if pane != nil, !points.isEmpty {
                return ControlResponse(ok: false, error: PaneOverlayError.pointsConflict)
            }
            if let percent = request.args?.sizePercent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100")
            }
            if let failure = Self.overlayPointFailure(points) { return failure }
            if !points.isEmpty, request.args?.sizePercent == nil {
                return ControlResponse(ok: false, error: OverlayPointError.needsPercent)
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: page == nil ? request.args?.cwd : nil,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: pane,
                                                resolved: request.args?.resolved ?? false,
                                                page: page,
                                                navigation: request.args?.navigation ?? false,
                                                javascript: request.args?.javascript ?? false,
                                                chromeless: request.args?.chromeless ?? false,
                                                persistent: request.args?.persistent ?? false,
                                                browse: request.args?.browse ?? false,
                                                rebased: rebased,
                                                rebasedDiff: rebasedDiff,
                                                rebasedView: rebasedView,
                                                rebasedProject: request.args?.project,
                                                rebasedOnClose: request.args?.onClose,
                                                points: points
                                              ))
        case .sessionOverlayReload:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.reloadSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                    current: request.args?.current ?? false)
            }
        case .sessionOverlayNavigate:
            guard let navigation = request.args?.to.flatMap(HtmlNavigation.init(rawValue:)) else {
                return ControlResponse(ok: false, error: OverlayHtmlError.navigation)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.navigateSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                      navigation: navigation)
            }
        case .sessionOverlayClose:
            if let overlay = request.args?.overlay {
                guard request.args?.pane == nil else {
                    return ControlResponse(ok: false, error: "session.overlay.close: --overlay cannot be combined with --pane")
                }
                guard let id = UUID(uuidString: overlay) else {
                    return ControlResponse(ok: false, error: "session.overlay.close: invalid --overlay id")
                }
                return actions.closeSessionOverlay(request.target, window: request.args?.window, overlay: id)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.closeSessionOverlay(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayResize:
            // pane overlays are always full, so ANY `--pane` is refused here, valid spelling or not.
            if request.args?.pane != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported)
            }
            let wantsFull = request.args?.full == true
            let percent = request.args?.sizePercent
            let points = OverlayPointSize(width: request.args?.width, height: request.args?.height)
            if wantsFull, percent != nil {
                return ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if wantsFull, !points.isEmpty {
                return ControlResponse(ok: false, error: OverlayPointError.fullConflict)
            }
            if !wantsFull, percent == nil, points.isEmpty {
                return ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent, --width/--height or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100")
            }
            if let failure = Self.overlayPointFailure(points) { return failure }
            if points.isEmpty {
                return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                    sizePercent: wantsFull ? nil : percent)
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: percent, points: points)
        case .sessionOverlayResult:
            if let page = request.args?.page {
                guard let id = UUID(uuidString: page) else { return ControlResponse(ok: false, error: OverlayHtmlError.invalidPageID) }
                return actions.htmlPageResult(id)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.sessionOverlayResult(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlaySubmit:
            guard let value = request.args?.value else { return ControlResponse(ok: false, error: OverlayHtmlError.submitValue) }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.submitSessionOverlay(request.target, window: request.args?.window, pane: pane, value: value)
            }
        case .sessionOverlayCopy:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.copySessionOverlaySelection(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayText:
            return dispatchSessionOverlayText(request)
        case .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle:
            let mode: OverlayVisibilityMode = request.cmd == .sessionOverlayHide ? .hide
                : (request.cmd == .sessionOverlayShow ? .show : .toggle)
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.setSessionOverlayVisibility(request.target, window: request.args?.window, pane: pane,
                                                           mode: mode)
            }
        case .sessionOverlayJobRun:
            guard let job = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "session.overlay.job.run requires a job id")
            }
            guard UUID(uuidString: job) != nil else { return ControlResponse(ok: false, error: "invalid job id") }
            return actions.claimOverlayJob(job)
        case .sessionOverlayPageServe:
            guard let token = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "session.overlay.page.serve requires a page token")
            }
            guard UUID(uuidString: token) != nil else { return ControlResponse(ok: false, error: "invalid page token") }
            return actions.claimPageServe(token)
        default:
            preconditionFailure("dispatchSessionOverlayCommand called for \(request.cmd.rawValue)")
        }
    }

    enum RebasedViewParse {
        case view(RebasedView?)
        case rejected(ControlResponse)
    }

    static func parseRebasedView(_ args: ControlArgs?, command: String = "session.overlay.open",
                                 requiresRebasedFlag: Bool = true) -> RebasedViewParse {
        let reject = { (detail: String) in RebasedViewParse.rejected(ControlResponse(ok: false, error: command + ": " + detail)) }
        if requiresRebasedFlag && args?.rebased != true {
            let flags: [(Bool, String)] = [
                (args?.diff != nil, "--diff"), (args?.workingTree == true, "--working-tree"),
                (args?.file != nil, "--file"), (args?.project != nil, "--project"), (args?.onClose != nil, "--on-close")
            ]
            if let flag = flags.first(where: { $0.0 }) { return reject(flag.1 + " requires --rebased") }
        }
        if !requiresRebasedFlag {
            if args?.project != nil { return reject("--project is supported only by session.overlay.open --rebased") }
            if args?.onClose != nil { return reject("--on-close is supported only by session.overlay.open --rebased") }
            if args?.pane != nil { return reject("--pane is supported only by session.overlay.open --rebased") }
            if args?.rebased != nil { return reject("--rebased is supported only by session.overlay.open") }
        }
        if args?.file != nil && args?.diff != nil { return reject("--file cannot be combined with --diff") }
        if args?.workingTree == true && args?.diff == nil { return reject("--working-tree requires --diff") }
        if let spec = args?.diff {
            guard RebasedDiff(spec: spec) != nil else { return reject("invalid --diff range") }
            guard let view = RebasedView(diff: spec, workingTree: args?.workingTree ?? false) else {
                return reject("--working-tree requires a default head or a merge-base range")
            }
            return .view(view)
        }
        if let spec = args?.file {
            guard let target = RebasedFileTarget(spec: spec) else { return reject("invalid --file target") }
            return .view(.file(path: target.path, line: target.line))
        }
        return .view(nil)
    }

    enum OverlayContent {
        case rejected(ControlResponse)
        case program
        case page(HtmlSource)
        case rebased
    }

    private static func overlayPointFailure(_ points: OverlayPointSize) -> ControlResponse? {
        guard [points.width, points.height].allSatisfy({ ($0 ?? 1) > 0 }) else {
            return ControlResponse(ok: false, error: OverlayPointError.notPositive)
        }
        return nil
    }

    static func overlayContent(command: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        if args?.rebased == true {
            let conflicts: [(Bool, String)] = [
                (!command.isEmpty, "COMMAND"), (args?.html != nil, "--html"), (args?.url != nil, "--url"),
                (args?.wait == true, "--wait"), (args?.javascript == true, "--js"),
                (args?.navigation == true, "--navigation"), (args?.chromeless == true, "--chromeless"),
                (args?.persistent == true, "--persistent"), (args?.browse == true, "--browse"), (args?.color != nil, "--background-color"),
                (args?.image != nil, "--image")
            ]
            if let conflict = conflicts.first(where: { $0.0 }) {
                return reject("session.overlay.open: --rebased cannot be combined with \(conflict.1)")
            }
            return .rebased
        }
        if let image = args?.image {
            guard command.isEmpty, args?.html == nil, args?.url == nil else { return reject(OverlayHtmlError.oneSource) }
            return imageContent(image, args: args)
        }
        switch (args?.html, args?.url) {
        case (nil, nil):
            if args?.navigation == true { return reject(OverlayHtmlError.navigationWithoutPage) }
            if args?.javascript == true { return reject(OverlayHtmlError.javascriptWithoutPage) }
            if args?.chromeless == true { return reject(OverlayHtmlError.chromelessRequiresFile) }
            if args?.persistent == true { return reject(OverlayHtmlError.persistentRequiresURL) }
            if args?.browse == true { return reject(OverlayHtmlError.browseRequiresURL) }
            return command.isEmpty ? reject("session.overlay.open requires a command") : .program
        case (.some, .some):
            return reject(OverlayHtmlError.htmlAndURL)
        case (.some(let html), nil):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndHtml) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithHtml) }
            if args?.chromeless == true, args?.navigation == true { return reject(OverlayHtmlError.chromelessWithNavigation) }
            if args?.persistent == true { return reject(OverlayHtmlError.persistentRequiresURL) }
            if args?.browse == true { return reject(OverlayHtmlError.browseRequiresURL) }
            if let error = HtmlOverlay.grantError(file: html, grantRoot: args?.cwd) {
                return reject("session.overlay.open: \(error)")
            }
            return .page(.file(path: html, grantRoot: args?.cwd))
        case (nil, .some(let text)):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndURL) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithURL) }
            if args?.cwd != nil { return reject(OverlayHtmlError.cwdWithURL) }
            if args?.chromeless == true, args?.navigation == true { return reject(OverlayHtmlError.chromelessWithNavigation) }
            if args?.chromeless == true, args?.browse == true { return reject(OverlayHtmlError.chromelessWithBrowse) }
            guard let url = HtmlSource.webURL(text) else { return reject(OverlayHtmlError.invalidURL) }
            if args?.chromeless == true, !HtmlSource.isLoopback(text) { return reject(OverlayHtmlError.chromelessRequiresLoopback) }
            return .page(.url(url))
        }
    }

    private static func imageContent(_ path: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        let flags = [args?.wait, args?.navigation, args?.javascript, args?.chromeless, args?.persistent, args?.browse]
        if args?.cwd != nil || flags.contains(true) { return reject(OverlayHtmlError.imageOptions) }
        guard path.hasPrefix("/") else { return reject(OverlayHtmlError.imageNotAbsolute) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard LinkPolicy.imageExtensions.contains(url.pathExtension.lowercased()) else {
            return reject(OverlayHtmlError.imageType)
        }
        return .page(.image(path: url.path))
    }

    /// The extent is checked before the pane, so the same flags produce the same first error here and on
    /// `session.text`.
    private func dispatchSessionOverlayText(_ request: ControlRequest) -> ControlResponse {
        let all: Bool
        let lines: Int?
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let parsedAll, let parsedLines):
            all = parsedAll
            lines = parsedLines
        }
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let pane):
            return actions.readSessionOverlayText(request.target, window: request.args?.window,
                                                  options: ControlSessionOverlayTextOptions(pane: pane,
                                                                                            all: all,
                                                                                            lines: lines))
        }
    }
}
