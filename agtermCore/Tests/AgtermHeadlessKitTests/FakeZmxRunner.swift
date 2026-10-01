import Foundation
import AgtermHeadlessKit

final class FakeZmxRunner: ZmxRunning, @unchecked Sendable {
    struct Call: Equatable {
        var arguments: [String]
        var environment: [String: String]
        var workingDirectory: String?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var results: [ZmxResult] = []
    private let respond: @Sendable ([String]) -> ZmxResult

    /// `respond` answers by argv; the default succeeds with no output.
    init(respond: @escaping @Sendable ([String]) -> ZmxResult = { _ in .ok("") }) {
        self.respond = respond
    }

    func enqueue(_ result: ZmxResult) { lock.withLock { results.append(result) } }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func run(_ arguments: [String], environment: [String: String], workingDirectory: String?,
             timeout: TimeInterval) -> ZmxResult {
        lock.withLock { recorded.append(Call(arguments: arguments, environment: environment, workingDirectory: workingDirectory)) }
        if let result = lock.withLock({ results.isEmpty ? nil : results.removeFirst() }) { return result }
        return respond(arguments)
    }
}
