import XCTest
@testable import agterm

final class RebasedStateLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-state-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFreeLockIsTakenForTheBodyAndReleasedAfterIt() throws {
        let holder = RebasedStateLock.Holder()
        var ran = false
        try holder.withLockIfFree(directory) {
            ran = true
            XCTAssertThrowsError(try RebasedStateLock.lock(directory))
        }
        XCTAssertTrue(ran)
        let descriptor = try RebasedStateLock.lock(directory)
        close(descriptor)
    }

    func testALockHeldElsewhereRefusesWithoutRunningTheBody() throws {
        let other = try RebasedStateLock.lock(directory)
        defer { close(other) }
        var ran = false
        XCTAssertThrowsError(try RebasedStateLock.Holder().withLockIfFree(directory) { ran = true }) { error in
            XCTAssertEqual(error as? RebasedRuntimeError, .failed(RebasedStateLock.message))
        }
        XCTAssertFalse(ran)
    }

    func testAnAcquireDuringTheBodyKeepsTheLock() throws {
        let holder = RebasedStateLock.Holder()
        try holder.withLockIfFree(directory) { try holder.acquire(directory) }
        XCTAssertThrowsError(try RebasedStateLock.lock(directory))
    }

    func testAHeldLockRunsTheBodyAndStaysHeld() throws {
        let holder = RebasedStateLock.Holder()
        try holder.acquire(directory)
        var ran = false
        try holder.withLockIfFree(directory) { ran = true }
        XCTAssertTrue(ran)
        XCTAssertThrowsError(try RebasedStateLock.lock(directory))
    }

    func testAHolderReleasesItsLockWhenItGoesAway() throws {
        var holder: RebasedStateLock.Holder? = RebasedStateLock.Holder()
        try holder?.acquire(directory)
        XCTAssertThrowsError(try RebasedStateLock.lock(directory))
        holder = nil
        let descriptor = try RebasedStateLock.lock(directory)
        close(descriptor)
    }
}
