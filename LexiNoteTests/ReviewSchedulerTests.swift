import XCTest
@testable import LexiNote

final class ReviewSchedulerTests: XCTestCase {
    func testNewCardIsDueTomorrow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let word = VocabWord(term: "Context", createdAt: now)
        XCTAssertEqual(word.normalizedTerm, "context")
        XCTAssertEqual(VocabWord.normalize("  Context,  "), "context")
        XCTAssertEqual(word.nextReviewAt.timeIntervalSince(now), 24 * 60 * 60, accuracy: 1)
    }

    func testRatingsChangeSchedule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let word = VocabWord(term: "context")
        ReviewScheduler.apply(.remembered, to: word, now: now)
        XCTAssertEqual(word.reviewStage, 1)
        XCTAssertEqual(word.nextReviewAt.timeIntervalSince(now), 3 * 24 * 60 * 60, accuracy: 1)

        ReviewScheduler.apply(.unsure, to: word, now: now)
        XCTAssertEqual(word.reviewStage, 1)
        XCTAssertEqual(word.nextReviewAt.timeIntervalSince(now), 24 * 60 * 60, accuracy: 1)

        ReviewScheduler.apply(.forgot, to: word, now: now)
        XCTAssertEqual(word.reviewStage, 0)
        XCTAssertEqual(word.nextReviewAt.timeIntervalSince(now), 10 * 60, accuracy: 1)
        XCTAssertEqual(word.reviewCount, 3)

        word.reviewStage = Int.max
        ReviewScheduler.apply(.remembered, to: word, now: now)
        XCTAssertEqual(word.reviewStage, ReviewScheduler.maximumStage)
    }

    func testBeijingCalendarAcrossMidnight() {
        let instant = Date(timeIntervalSince1970: 1_767_196_200) // 2025-12-31 15:50 UTC
        let next = BeijingTime.addingDays(1, to: instant)
        let start = BeijingTime.calendar.dateComponents([.year, .month, .day, .hour], from: instant)
        let end = BeijingTime.calendar.dateComponents([.year, .month, .day, .hour], from: next)
        XCTAssertEqual(start.day, 31)
        XCTAssertEqual(end.day, 1)
        XCTAssertEqual(start.hour, end.hour)
    }

    func testRecommendationCadenceCountsOnlyActiveMinutes() {
        var cadence = RecommendationCadence(targetMinutes: 30)
        for _ in 0..<20 { XCTAssertFalse(cadence.tick(isActive: true)) }
        for _ in 0..<100 { XCTAssertFalse(cadence.tick(isActive: false)) }
        for _ in 0..<9 { XCTAssertFalse(cadence.tick(isActive: true)) }
        XCTAssertTrue(cadence.tick(isActive: true, nextTarget: { 120 }))
        XCTAssertEqual(cadence.activeMinutes, 0)
        XCTAssertEqual(cadence.targetMinutes, 120)
    }
}
