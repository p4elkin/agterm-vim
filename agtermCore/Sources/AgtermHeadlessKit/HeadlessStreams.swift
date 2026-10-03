import Foundation
import agtermCore

@MainActor
public protocol HeadlessStreams: AnyObject {
    /// Nil means the adapter owns the connection, including its initial reply and eventual close.
    func adopt(session: UUID, fd: Int32) -> ControlResponse?
    func closeStreams(session: UUID)
    /// Writes `reply`, the ok answer to a job claim, then hands every line the helper sends to `onLine` and its
    /// close to `onClose`. Nil when the reply could not be written; the connection is closed then.
    func adoptJob(fd: Int32, reply: ControlResponse, onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor () -> Void) -> (any HeadlessJobTransport)?
}

/// A claimed job's helper connection, after its reply.
@MainActor
public protocol HeadlessJobTransport: AnyObject {
    /// False when the line cannot be queued.
    func send(_ line: Data) -> Bool
    func shutdown()
}
