import Foundation
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RebasedOnCloseRunnerTests: XCTestCase {
    func testTheShellUsesTheCapturedDirectoryAndEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-on-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("marker")
        let command = RebasedOnClose(command: "printf '%s\\n' \"$REVIEW_MARKER\" > marker", cwd: directory.path,
                                    environment: ["REVIEW_MARKER": "captured", "PATH": "/usr/bin:/bin"])
        XCTAssertTrue(RebasedOnCloseRunner.run(command))
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: marker, encoding: .utf8)) == "captured\n"
        }, object: nil)
        wait(for: [written], timeout: 5)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "captured\n")
    }

    func testAMissingDirectoryLogsTheSpawnFailure() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-on-close-\(UUID().uuidString)")
        var messages: [String] = []
        XCTAssertFalse(RebasedOnCloseRunner.run(RebasedOnClose(command: "true", cwd: missing.path, environment: [:]),
                                                logFailure: { messages.append($0) }))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("failed to spawn"))
    }
}
