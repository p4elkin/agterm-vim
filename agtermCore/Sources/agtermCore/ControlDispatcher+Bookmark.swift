import Foundation

// The `session.bookmark` family's dispatch (fork only). Its own file (like `+Hud`/`+Pick`) because
// `ControlDispatcher.swift` sits at the file-length limit.
extension ControlDispatcher {
    /// `go` deliberately routes onto the EXISTING `session.search` action with the turn's
    /// `TurnMark.needle` — the jump IS a search, and a second viewport-moving path is what the design
    /// forbids. Its `count` 0 answer means the mark has left scrollback; the stored prompt (from `list`)
    /// is then all that remains of the turn. `async` only for that search arm.
    func dispatchSessionBookmark(_ request: ControlRequest) async -> ControlResponse {
        let args = request.args
        if let turn = args?.turn, turn <= 0 {
            return ControlResponse(ok: false, error: "--turn must be greater than 0")
        }
        switch request.cmd {
        case .sessionBookmarkAdd:
            return actions.addSessionBookmark(request.target, window: args?.window,
                                              turn: args?.turn, prompt: args?.text ?? "")
        case .sessionBookmarkList:
            return actions.listSessionBookmarks(request.target, window: args?.window,
                                                all: args?.all ?? false)
        case .sessionBookmarkGo:
            guard let turn = args?.turn else {
                return ControlResponse(ok: false, error: "session.bookmark.go requires --turn")
            }
            return await actions.searchSession(request.target, window: args?.window,
                                               text: TurnMark.needle(for: turn), to: nil)
        case .sessionBookmarkRemove:
            guard let turn = args?.turn else {
                return ControlResponse(ok: false, error: "session.bookmark.remove requires --turn")
            }
            return actions.removeSessionBookmark(request.target, window: args?.window, turn: turn)
        default:
            preconditionFailure("unexpected bookmark command: \(request.cmd.rawValue)")
        }
    }
}
