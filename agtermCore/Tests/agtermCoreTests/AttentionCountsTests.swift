import Testing
@testable import agtermCore

struct AttentionCountsTests {
    @Test func blockedStatusesLandInBlockedBucketOnly() {
        let counts = AttentionCounts.make(statuses: [.blocked, .blocked], activeUnseen: 0)
        #expect(counts.blocked == 2)
        #expect(counts.active == 0)
        #expect(counts.completed == 0)
        #expect(counts.unseen == 0)
    }

    @Test func activeStatusesLandInActiveBucketOnly() {
        let counts = AttentionCounts.make(statuses: [.active, .active, .active], activeUnseen: 0)
        #expect(counts.active == 3)
        #expect(counts.blocked == 0)
        #expect(counts.completed == 0)
    }

    @Test func completedStatusesLandInCompletedBucketOnly() {
        let counts = AttentionCounts.make(statuses: [.completed], activeUnseen: 0)
        #expect(counts.completed == 1)
        #expect(counts.blocked == 0)
        #expect(counts.active == 0)
    }

    @Test func mixedStatusesCountEachCategory() {
        let counts = AttentionCounts.make(
            statuses: [.blocked, .active, .completed, .active, .blocked, .active],
            activeUnseen: 4
        )
        #expect(counts.blocked == 2)
        #expect(counts.active == 3)
        #expect(counts.completed == 1)
        #expect(counts.unseen == 4)
        #expect(!counts.isEmpty)
    }

    @Test func noStatusesAndNoUnseenIsEmpty() {
        #expect(AttentionCounts.make(statuses: [], activeUnseen: 0).isEmpty)
    }

    @Test func unseenAlonePassesThroughAndIsNotEmpty() {
        let counts = AttentionCounts.make(statuses: [], activeUnseen: 7)
        #expect(counts.unseen == 7)
        #expect(!counts.isEmpty)
    }

    @Test func idleIsCountedIntoNothingAndStaysEmpty() {
        let counts = AttentionCounts.make(statuses: [.idle, .idle], activeUnseen: 0)
        #expect(counts.blocked == 0)
        #expect(counts.active == 0)
        #expect(counts.completed == 0)
        #expect(counts.isEmpty)
    }

    @Test func idleDoesNotDisturbTheOtherBuckets() {
        let counts = AttentionCounts.make(statuses: [.idle, .blocked, .idle, .completed], activeUnseen: 0)
        #expect(counts.blocked == 1)
        #expect(counts.completed == 1)
        #expect(counts.active == 0)
    }
}
