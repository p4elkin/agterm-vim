import agtermCore
import AgtermHeadlessKit
import Foundation
import Glibc

/// A claimed job's helper connection after its ok reply: lines out through a bounded writer queue, the helper's
/// lines in on a reader thread, both hopping to the main actor.
@MainActor
final class JobStream: HeadlessJobTransport {
    static let maxPending = 16

    private let fd: Int32
    private let writer = DispatchQueue(label: "agterm-headless.job.writer")
    private var pending = 0
    private var shut = false

    init(fd: Int32) { self.fd = fd }

    func start(onLine: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor () -> Void) {
        let fd = fd
        // strong on purpose: the reader keeps the stream alive until the helper's side ends
        Thread { [self] in
            while let line = UnixSocket.readLine(fd, limit: PresentationCodec.maxFrameBytes) {
                DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.shut = true
                    self.writer.async { Glibc.close(fd) }
                    onClose()
                }
            }
        }.start()
    }

    func send(_ line: Data) -> Bool {
        guard !shut, pending < Self.maxPending else { return false }
        pending += 1
        let fd = fd
        writer.async { [weak self] in
            // a failed write ends the link, as `ControlStreamOwner`'s writer does; the reader then reports the close
            let written = UnixSocket.writeAll(fd, line)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.pending -= 1
                    if !written { self?.shutdown() }
                }
            }
        }
        return true
    }

    func shutdown() {
        guard !shut else { return }
        shut = true
        Glibc.shutdown(fd, Int32(SHUT_RDWR))
    }
}
