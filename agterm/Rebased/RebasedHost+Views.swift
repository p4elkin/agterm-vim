import Foundation
import agtermCore

extension RebasedHost {
    static let viewDeadline: TimeInterval = 60
    static let viewDeadlineMessage = "view did not open within 60 s"

    @discardableResult
    func requestView(overlay id: UUID, view: RebasedView) -> String {
        if let entry = entries[id], let session = store(entry.session)?.session(withID: entry.session),
           let host = session.remoteHost, case .diff = view {
            let prefix = host + ":"
            let source = overlay(entry)?.source
            let path = source.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil } ?? session.focusedCwd
            if let store = store(entry.session) {
                switch openRemote(in: store, session: session, path: path, sizePercent: nil, view: view, pane: nil) {
                case .success(let opened): if let request = opened.request { return request }
                case .failure(let failure):
                    let request = issueView(overlay: id, view: view)
                    failView(overlay: id, request: request, reason: failure.message)
                    return request
                }
            }
        }
        let request = issueView(overlay: id, view: view)
        sendView(overlay: id)
        return request
    }

    func issueView(overlay id: UUID, view: RebasedView) -> String {
        let request = RebasedViewRequest(view: view)
        if let entry = entries[id] {
            store(entry.session)?.session(withID: entry.session)?.updateRebasedOverlay(id) {
                $0.view = request
                if case .diff(let diff, _) = view { $0.diff = diff }
            }
        }
        return request.id
    }

    func sendView(overlay id: UUID) {
        guard let entry = entries[id], visible[entry.project] == id, !fetching.contains(entry.session),
              let held = overlay(entry), !held.hidden, let request = held.view, request.state == .queued,
              let session = store(entry.session)?.session(withID: entry.session) else { return }
        let pane = session.rebasedPlacement?.pane != nil
        session.updateRebasedOverlay(id) { $0.view?.sent() }
        let answer = runtime.call(request.view.bridgeVerb,
                                  request.view.bridgeArgument(request: request.id, project: entry.project, pane: pane))
        guard answer == "ok" else { failView(overlay: id, request: request.id, reason: answer); return }
        after(Self.viewDeadline) { [weak self] in
            guard let self, let entry = self.entries[id] else { return }
            self.store(entry.session)?.session(withID: entry.session)?.updateRebasedOverlay(id) {
                $0.view?.timedOut(request: request.id, reason: Self.viewDeadlineMessage)
            }
        }
    }

    func failView(overlay id: UUID, request: String, reason: String) {
        guard let entry = entries[id] else { return }
        store(entry.session)?.session(withID: entry.session)?.updateRebasedOverlay(id) {
            $0.view?.apply(event: .failed(reason), request: request)
        }
    }

    func handleViewEvent(kind: String, payload: String) {
        let fields = payload.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2,
              let entry = entries.values.first(where: { overlay($0)?.view?.id == fields[0] }) else { return }
        let event: RebasedViewRequest.Event = kind == "viewOpened" ? .opened(fields[1]) : .failed(fields[1])
        store(entry.session)?.session(withID: entry.session)?.updateRebasedOverlay(entry.id) {
            $0.view?.apply(event: event, request: fields[0])
        }
    }

    func beginPortLookup() {
        guard idePort == nil else { return }
        let generation = UUID(), deadline = now().addingTimeInterval(30)
        portLookup = generation
        after(30) { [weak self] in
            if self?.portLookup == generation { self?.portLookup = nil }
        }
        after(0.5) { [weak self] in self?.pollPort(generation: generation, deadline: deadline, delay: 0.5) }
    }

    private func pollPort(generation: UUID, deadline: Date, delay: TimeInterval) {
        guard portLookup == generation, idePort == nil, now() < deadline else { return }
        let runtime = runtime, result = ResultBox<String>()
        offMain({ result.set { runtime.call("port", "") } }, { [weak self] in
            guard let self, self.portLookup == generation, self.now() < deadline else { return }
            if case .success(let response)? = result.value,
               let port = Int(response.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) {
                self.idePort = port
                self.portLookup = nil
                return
            }
            let next = min(delay * 2, 4)
            self.after(min(next, deadline.timeIntervalSince(self.now()))) { [weak self] in
                self?.pollPort(generation: generation, deadline: deadline, delay: next)
            }
        })
    }
}
