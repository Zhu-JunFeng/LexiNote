import Foundation

enum BeijingTime {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    static func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}

enum ReviewRating: String, CaseIterable, Identifiable {
    case forgot = "忘记"
    case unsure = "模糊"
    case remembered = "记住"

    var id: String { rawValue }
}

enum ReviewScheduler {
    private static let intervals = [3, 7, 14, 30, 60]
    static let maximumStage = intervals.count

    static func apply(_ rating: ReviewRating, to word: VocabWord, now: Date = .now) {
        switch rating {
        case .forgot:
            word.reviewStage = 0
            word.nextReviewAt = now.addingTimeInterval(10 * 60)
        case .unsure:
            word.nextReviewAt = BeijingTime.addingDays(1, to: now)
        case .remembered:
            word.reviewStage = min(max(word.reviewStage, 0), intervals.count - 1) + 1
            let days = intervals[word.reviewStage - 1]
            word.nextReviewAt = BeijingTime.addingDays(days, to: now)
        }
        word.reviewCount += 1
        word.updatedAt = now
    }
}
