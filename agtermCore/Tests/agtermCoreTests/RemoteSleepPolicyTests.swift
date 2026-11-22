import Foundation
import Testing
@testable import agtermCore

struct RemoteSleepPolicyTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func row(eligible: Bool = true, asleep: Bool = false, offScreenMinutes: Double?) -> RemoteSleepPolicy.Candidate {
        RemoteSleepPolicy.Candidate(id: UUID(), eligible: eligible, asleep: asleep,
                                    offScreenSince: offScreenMinutes.map { now.addingTimeInterval(-$0 * 60) })
    }

    @Test func aRowOffScreenForTheSettingSleepsAndOneMinuteLessStays() {
        let due = row(offScreenMinutes: 30)
        let early = row(offScreenMinutes: 29)
        #expect(RemoteSleepPolicy.rowsToSleep(rows: [due, early], now: now, after: 30) == [due.id])
    }

    @Test func onScreenIneligibleAndAsleepRowsAreNotListed() {
        let rows = [row(offScreenMinutes: nil), row(eligible: false, offScreenMinutes: 60),
                    row(asleep: true, offScreenMinutes: 60)]
        #expect(RemoteSleepPolicy.rowsToSleep(rows: rows, now: now, after: 30).isEmpty)
    }

    @Test func settingZeroSleepsNothing() {
        #expect(RemoteSleepPolicy.rowsToSleep(rows: [row(offScreenMinutes: 600)], now: now, after: 0).isEmpty)
    }
}
