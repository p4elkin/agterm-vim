import Foundation
import XCTest
import agtermCore
@testable import agterm

final class RebasedMirrorRefreshTests: XCTestCase {
    private var stateDirectory: URL!
    private let mirror = RebasedMirror(host: "p4linux", path: "/home/s/repo/sub")!
    private let top = "/home/s/repo"

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private var hashDirectory: URL {
        mirror.directory(top: top, stateDirectory: stateDirectory).deletingLastPathComponent()
    }

    /// Answers the ssh query with `top`, then each git step with the next status in `steps`.
    private func fake(query: Int32 = 0, steps: [Int32] = [0, 0, 0]) -> ([String], TimeInterval) -> RebasedMirrorRefresh.Outcome {
        var remaining = steps
        return { [top] argv, _ in
            if argv.first == "/usr/bin/ssh" {
                return RebasedMirrorRefresh.Outcome(status: query, stdout: query == 0 ? top + "\n" : "", reason: "exit \(query)")
            }
            let status = remaining.isEmpty ? 0 : remaining.removeFirst()
            return RebasedMirrorRefresh.Outcome(status: status, stdout: "", reason: "exit \(status)")
        }
    }

    func testAFetchThatFailsMidwayStillLeavesTheMarkerWrittenAfterTheDirectory() {
        let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, execute: fake(steps: [0, 1]))
        guard case .failure = result else { return XCTFail("the fetch failed, so the refresh fails: \(result)") }
        XCTAssertEqual(RebasedMirrorMarker.read(from: hashDirectory)?.source, "p4linux:/home/s/repo")
    }

    func testAFailedSshQueryLeavesAnExistingMarkerUnchanged() throws {
        try FileManager.default.createDirectory(at: hashDirectory, withIntermediateDirectories: true)
        let old = RebasedMirrorMarker(source: "p4linux:/home/s/repo", lastOpened: Date(timeIntervalSince1970: 1_791_000_000))
        try old.write(to: hashDirectory)
        let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory, execute: fake(query: 255))
        guard case .failure = result else { return XCTFail("the query failed, so the refresh fails: \(result)") }
        XCTAssertEqual(RebasedMirrorMarker.read(from: hashDirectory), old)
    }

    func testASuccessfulRefreshLeavesAMarkerNoOlderThanItsStart() throws {
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let steps = fake()
        let firstMarker = hashDirectory.appendingPathComponent(RebasedMirrorMarker.fileName)
        // drops the marker written before the fetch, so only the write after the last step can leave one
        let result = RebasedMirrorRefresh.run(mirror, stateDirectory: stateDirectory) { argv, timeout in
            if argv.contains("checkout") { try? FileManager.default.removeItem(at: firstMarker) }
            return steps(argv, timeout)
        }
        XCTAssertEqual(try result.get().source, "p4linux:/home/s/repo")
        let marker = try XCTUnwrap(RebasedMirrorMarker.read(from: hashDirectory))
        XCTAssertEqual(marker.source, "p4linux:/home/s/repo")
        XCTAssertGreaterThanOrEqual(marker.lastOpened, start)
    }
}
