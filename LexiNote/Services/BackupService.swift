import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Imports and exports the user's word book as a versioned, local JSON file.
@MainActor
final class BackupService {
    struct ImportSummary {
        let imported: Int
        let skipped: Int
    }

    enum BackupError: LocalizedError {
        case unsupportedVersion(Int)
        case invalidWord(Int)
        case nonLocalFile

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "不支持此备份版本（\(version)）。请更新 LexiNote 后重试。"
            case .invalidWord(let index):
                return "备份中的第 \(index + 1) 个单词数据无效，未导入任何内容。"
            case .nonLocalFile:
                return "请选择本地 JSON 文件。"
            }
        }
    }

    /// Presents a save panel and writes a complete word book. Returns nil if cancelled.
    @discardableResult
    func exportWords(_ context: ModelContext) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "LexiNote-\(Self.fileDateFormatter.string(from: .now)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        try exportWords(context, to: url)
        return url
    }

    /// Writes a backup to a specified local file; useful for noninteractive backups and tests.
    func exportWords(_ context: ModelContext, to url: URL) throws {
        guard url.isFileURL else { throw BackupError.nonLocalFile }
        let words = try context.fetch(FetchDescriptor<VocabWord>())
        let records = words.map(WordRecord.init)
            .sorted { $0.normalizedTerm < $1.normalizedTerm }
        let document = BackupDocument(version: 1, exportedAt: .now, words: records)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    /// Presents an open panel and merges a backup into the word book. Returns nil if cancelled.
    @discardableResult
    func importWords(into context: ModelContext) throws -> ImportSummary? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        return try importWords(from: url, into: context)
    }

    /// Merges a specified local backup. Duplicate terms or IDs are counted as skipped.
    func importWords(from url: URL, into context: ModelContext) throws -> ImportSummary {
        guard url.isFileURL else { throw BackupError.nonLocalFile }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let document = try decoder.decode(BackupDocument.self, from: data)
        guard document.version == 1 else {
            throw BackupError.unsupportedVersion(document.version)
        }

        // Reject a malformed file before inserting any records.
        for (index, record) in document.words.enumerated() {
            guard !record.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.normalizedTerm == VocabWord.normalize(record.term),
                  (0...ReviewScheduler.maximumStage).contains(record.reviewStage),
                  record.reviewCount >= 0 else {
                throw BackupError.invalidWord(index)
            }
        }

        let existing = try context.fetch(FetchDescriptor<VocabWord>())
        var knownTerms = Set(existing.map(\.normalizedTerm))
        var knownIDs = Set(existing.map(\.id))
        var imported = 0
        var skipped = 0

        for record in document.words {
            guard !knownTerms.contains(record.normalizedTerm),
                  !knownIDs.contains(record.id) else {
                skipped += 1
                continue
            }

            context.insert(record.makeWord())
            knownTerms.insert(record.normalizedTerm)
            knownIDs.insert(record.id)
            imported += 1
        }

        if imported > 0 { try context.save() }
        return ImportSummary(imported: imported, skipped: skipped)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = BeijingTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct BackupDocument: Codable {
    let version: Int
    let exportedAt: Date
    let words: [WordRecord]
}

private struct WordRecord: Codable {
    let id: UUID
    let term: String
    let normalizedTerm: String
    let chineseMeaning: String
    let englishMeaning: String
    let phonetic: String
    let example: String
    let note: String
    let createdAt: Date
    let updatedAt: Date
    let nextReviewAt: Date
    let reviewStage: Int
    let reviewCount: Int

    init(_ word: VocabWord) {
        id = word.id
        term = word.term
        normalizedTerm = word.normalizedTerm
        chineseMeaning = word.chineseMeaning
        englishMeaning = word.englishMeaning
        phonetic = word.phonetic
        example = word.example
        note = word.note
        createdAt = word.createdAt
        updatedAt = word.updatedAt
        nextReviewAt = word.nextReviewAt
        reviewStage = word.reviewStage
        reviewCount = word.reviewCount
    }

    func makeWord() -> VocabWord {
        VocabWord(
            id: id,
            term: term,
            chineseMeaning: chineseMeaning,
            englishMeaning: englishMeaning,
            phonetic: phonetic,
            example: example,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt,
            nextReviewAt: nextReviewAt,
            reviewStage: reviewStage,
            reviewCount: reviewCount
        )
    }
}
