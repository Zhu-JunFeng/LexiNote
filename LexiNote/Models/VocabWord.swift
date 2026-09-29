import Foundation
import SwiftData

@Model
final class VocabWord {
    var id: UUID
    var term: String
    var normalizedTerm: String
    var chineseMeaning: String
    var englishMeaning: String
    var phonetic: String
    var example: String
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var nextReviewAt: Date
    var reviewStage: Int
    var reviewCount: Int

    init(
        id: UUID = UUID(),
        term: String,
        chineseMeaning: String = "",
        englishMeaning: String = "",
        phonetic: String = "",
        example: String = "",
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        nextReviewAt: Date? = nil,
        reviewStage: Int = 0,
        reviewCount: Int = 0
    ) {
        self.id = id
        self.term = Self.clean(term)
        self.normalizedTerm = Self.normalize(term)
        self.chineseMeaning = chineseMeaning
        self.englishMeaning = englishMeaning
        self.phonetic = phonetic
        self.example = example
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nextReviewAt = nextReviewAt ?? BeijingTime.addingDays(1, to: createdAt)
        self.reviewStage = reviewStage
        self.reviewCount = reviewCount
    }

    static func normalize(_ term: String) -> String {
        clean(term)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    static func clean(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

@Model
final class LookupCache {
    var normalizedTerm: String
    var entryData: Data
    var fetchedAt: Date

    init(normalizedTerm: String, entryData: Data, fetchedAt: Date = .now) {
        self.normalizedTerm = normalizedTerm
        self.entryData = entryData
        self.fetchedAt = fetchedAt
    }
}
