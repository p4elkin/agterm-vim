import agtermCore
import Foundation

/// Hands a request the origin cannot answer to the session's presenting Mac and waits for its reply.
/// A pick or a page lives on the Mac that opened it, so later polls by its id go to that Mac; once its stream
/// is gone they get a final answer at once, never a wait. Ids that ended, or whose Mac is gone, are kept only up to
/// `retainedLimit` per table, oldest dropped first, as the Mac's own result registries keep theirs.
@MainActor
final class HeadlessForwarder {
    static let deadline: TimeInterval = 10
    static let retainedLimit = 32

    private struct Owner {
        let session: UUID
        let generation: Int
        let order: Int
        var ended = false
    }

    private struct Pending {
        let session: UUID
        let continuation: CheckedContinuation<Reply, Never>
    }

    private enum Reply {
        case answered(ControlResponse)
        case silent
    }

    private let hub: PresentationHub
    private let deadline: TimeInterval
    private let retainedLimit: Int
    private var pending: [String: Pending] = [:]
    private var picks: [String: Owner] = [:]
    private var pages: [String: Owner] = [:]
    private var opened = 0

    init(hub: PresentationHub, deadline: TimeInterval = HeadlessForwarder.deadline,
         retainedLimit: Int = HeadlessForwarder.retainedLimit) {
        self.hub = hub
        self.deadline = deadline
        self.retainedLimit = retainedLimit
    }

    /// `session` is the target resolved to one of this origin's sessions, nil when it named none.
    func forward(_ request: ControlRequest, session: UUID?) async -> ControlResponse {
        picks = trimmed(picks)
        pages = trimmed(pages)
        if let id = Self.pickID(request) {
            guard let owner = picks[id] else { return ControlResponse(ok: false, error: "unknown pick: \(id)") }
            guard isCurrent(owner) else {
                return ControlResponse(ok: true, result: ControlResult(pick: ControlPickResult(result: .cancelled)))
            }
            let response = await send(request, to: owner.session, retry: false).response
            if request.cmd == .pickCancel ? response.ok : response.result?.pick.map({ $0.result != .pending }) == true {
                picks[id]?.ended = true
            }
            return response
        }
        if let id = request.args?.page, request.cmd == .sessionOverlayResult {
            guard let owner = pages[id] else { return ControlResponse(ok: false, error: OverlayHtmlError.unknownPage) }
            guard isCurrent(owner) else {
                return ControlResponse(ok: true, result: ControlResult(pageOutcome: ControlHtmlPageOutcome(pageID: id, outcome: .dismissed)))
            }
            let response = await send(request, to: owner.session, retry: false).response
            if let outcome = response.result?.pageOutcome?.outcome, outcome != .pending { pages[id]?.ended = true }
            return response
        }
        guard let session else {
            return Self.refusal(request, "it needs --target naming a session on this origin")
        }
        guard hub.hasPresenter(session: session) else { return Self.refusal(request, "no Mac is presenting this session") }
        guard hub.presenterSupports("forward", session: session) else {
            return Self.refusal(request, "the presenting Mac does not support forwarding")
        }
        var sent = request
        sent.target = session.uuidString
        sent.args?.window = nil
        let (response, generation) = await send(sent, to: session, retry: true)
        if request.cmd == .pickOpen, response.ok, let id = response.result?.id {
            opened += 1
            picks[id] = Owner(session: session, generation: generation, order: opened)
        }
        if let id = response.result?.pageID {
            opened += 1
            pages[id] = Owner(session: session, generation: generation, order: opened)
        }
        return response
    }

    /// A reply from the presenter; one for a request that already timed out or failed is dropped.
    func receive(_ reply: PresentationForwarded) {
        pending.removeValue(forKey: reply.id)?.continuation.resume(returning: .answered(reply.response))
    }

    /// The session's presenter changed or left: what was waiting on it will get no reply.
    func presenterGone(session: UUID) {
        for (id, entry) in pending where entry.session == session { finish(id, with: .answered(Self.left)) }
    }

    /// The session ended: nothing can poll its picks or pages any more.
    func forget(session: UUID) {
        picks = picks.filter { $0.value.session != session }
        pages = pages.filter { $0.value.session != session }
    }

    /// A presenter silent past the deadline is dropped, so the role passes to the next live viewer: a Mac that
    /// took the role and went to sleep would otherwise hold it until the hub's stale timeout. `retry` sends a new
    /// request once more, to that next viewer. The generation is the presenter's that answered.
    private func send(_ request: ControlRequest, to session: UUID, retry: Bool) async -> (response: ControlResponse, generation: Int) {
        let generation = hub.presenterGeneration(session: session)
        switch await sendOnce(request, to: session) {
        case .answered(let response): return (response, generation)
        case .silent:
            if hub.presenterGeneration(session: session) == generation { hub.dropPresenter(session: session) }
            let next = hub.presenterGeneration(session: session)
            guard retry, hub.presenterSupports("forward", session: session),
                  case .answered(let response) = await sendOnce(request, to: session) else { return (Self.left, next) }
            return (response, next)
        }
    }

    private func sendOnce(_ request: ControlRequest, to session: UUID) async -> Reply {
        let id = UUID().uuidString
        let body = PresentationFrame.Body.controlForward(PresentationForward(id: id, request: request))
        guard (try? PresentationCodec.encode(PresentationFrame(gen: 0, rev: 0, body: body))) != nil else {
            return .answered(Self.refusal(request, "the request is larger than the presentation frame limit"))
        }
        return await withCheckedContinuation { continuation in
            pending[id] = Pending(session: session, continuation: continuation)
            guard hub.sendToPresenter(body, session: session) else { return finish(id, with: .answered(Self.left)) }
            let deadline = deadline
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                self?.finish(id, with: .silent)
            }
        }
    }

    private func finish(_ id: String, with reply: Reply) {
        pending.removeValue(forKey: id)?.continuation.resume(returning: reply)
    }

    /// Drops the oldest ids beyond the limit among those that ended or whose Mac is gone; a live one is never dropped.
    private func trimmed(_ table: [String: Owner]) -> [String: Owner] {
        let retired = table.filter { $0.value.ended || !isCurrent($0.value) }.sorted { $0.value.order < $1.value.order }
        guard retired.count > retainedLimit else { return table }
        var kept = table
        for (id, _) in retired.prefix(retired.count - retainedLimit) { kept[id] = nil }
        return kept
    }

    private func isCurrent(_ owner: Owner) -> Bool {
        hub.hasPresenter(session: owner.session) && hub.presenterGeneration(session: owner.session) == owner.generation
    }

    private static let left = ControlResponse(ok: false, error: "the presenting Mac left")

    private static func pickID(_ request: ControlRequest) -> String? {
        request.cmd == .pickResult || request.cmd == .pickCancel ? request.target : nil
    }

    private static func refusal(_ request: ControlRequest, _ reason: String) -> ControlResponse {
        ControlResponse(ok: false, error: "\(request.cmd.rawValue) cannot be forwarded: \(reason)")
    }
}
