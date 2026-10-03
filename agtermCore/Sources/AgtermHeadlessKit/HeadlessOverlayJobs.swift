import agtermCore
import Foundation

/// One helper's connection to a claimed job: the origin sends the launch context first, then any cancel; the
/// helper reports `started` and one terminal outcome. The Mac's `OverlayJobStream` does the same over its socket.
@MainActor
final class OverlayJobLink {
    let job: String
    private let transport: any HeadlessJobTransport
    private let jobs: OverlayJobs

    init(job: String, transport: any HeadlessJobTransport, jobs: OverlayJobs) {
        self.job = job
        self.transport = transport
        self.jobs = jobs
    }

    func send(_ frame: OverlayJobFrame) {
        guard let line = try? frame.line(), transport.send(line) else { return transport.shutdown() }
    }

    func receive(_ line: Data) {
        guard let frame = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) else { return transport.shutdown() }
        switch frame {
        case .started: jobs.started(job)
        case .exited(let code): jobs.finish(job, .exited(code))
        case .canceled: jobs.finish(job, .canceled)
        case .launchFailed: jobs.finish(job, .launchFailed)
        case .context, .cancel: transport.shutdown()
        }
    }

    func shutdown() { transport.shutdown() }
}

extension Headless {
    /// Answers `session.overlay.job.run`: the request is the claim, so an ok here is the one winner of the race
    /// against the job's launch deadline.
    func claimOverlayJob(_ job: String) -> ControlResponse {
        guard overlayJobs.claim(job, cancel: { [weak self] in self?.cancelJobHelper(job) }) != nil else {
            return ControlResponse(ok: false, error: "job not claimable")
        }
        scheduleOverlayJobExpiry(after: OverlayJobs.startWindow)
        return ControlResponse(ok: true, result: ControlResult(id: job))
    }

    /// Takes over the connection of a job whose claim was answered ok, and sends its launch context. A reply
    /// that never reached the helper leaves nobody to run the job.
    func adoptJob(_ job: String, fd: Int32, reply: ControlResponse) {
        guard let transport = streams.adoptJob(fd: fd, reply: reply,
                                               onLine: { [weak self] line in self?.jobLinks[job]?.receive(line) },
                                               onClose: { [weak self] in self?.jobClosed(job) }) else {
            return overlayJobs.helperGone(job)
        }
        let link = OverlayJobLink(job: job, transport: transport, jobs: overlayJobs)
        jobLinks[job] = link
        // a job that ended between its claim and this adoption must not launch, its queued cancel gone with it
        guard let claimed = overlayJobs.job(job), case .claimed = claimed.state else { return link.shutdown() }
        link.send(.context(claimed.context))
        if pendingJobCancels.remove(job) != nil { link.send(.cancel) }
    }

    /// Reaches a claimed job's helper. A cancel that arrives before its connection is adopted is held for it.
    func cancelJobHelper(_ job: String) {
        guard let link = jobLinks[job] else {
            pendingJobCancels.insert(job)
            return
        }
        link.send(.cancel)
    }

    private func jobClosed(_ job: String) {
        overlayJobs.helperGone(job)
        jobLinks[job] = nil
    }
}
