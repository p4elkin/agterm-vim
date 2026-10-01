import Foundation
import agtermCore

@MainActor
public protocol HeadlessStreams: AnyObject {
    /// Nil means the adapter owns the connection, including its initial reply and eventual close.
    func adopt(session: UUID, fd: Int32) -> ControlResponse?
    func closeStreams(session: UUID)
}
