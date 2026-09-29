import SwiftData
import XCTest
@testable import LexiNote

final class DictionaryAndBackupTests: XCTestCase {
    func testBundledDictionaryReturnsChineseAndEnglishOffline() async {
        let service = DictionaryService()
        let entry = await service.localEntry(term: "apple")
        XCTAssertEqual(entry.term.lowercased(), "apple")
        XCTAssertFalse(entry.chineseDefinitions.isEmpty)
        XCTAssertFalse(entry.englishSenses.isEmpty)
    }

    func testKnownInflectionsResolveToDictionaryHeadwords() async {
        let service = DictionaryService()
        let running = await service.preferredTerm(for: "running")
        let went = await service.preferredTerm(for: "went")
        let phrase = await service.preferredTerm(for: "take off")
        let inflectedPhrase = await service.preferredTerm(for: "running shoes")
        XCTAssertEqual(running, "run")
        XCTAssertEqual(went, "go")
        XCTAssertEqual(phrase, "take off")
        XCTAssertEqual(inflectedPhrase, "running shoes")
    }

    func testOnlineFallbackSuppliesExampleWhenPrimaryFails() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDictionaryURLProtocol.self]
        let service = DictionaryService(session: URLSession(configuration: configuration))
        let entry = await service.lookup(term: "context")
        XCTAssertTrue(entry.wasFetchedOnline)
        XCTAssertEqual(entry.onlineSource, "EnglishDictionaryAPI · Wiktionary")
        XCTAssertEqual(entry.englishSenses.first?.example, "Learn words in context.")
        XCTAssertFalse(entry.chineseDefinitions.isEmpty)
    }

    @MainActor
    func testBackupRoundTripPreservesReviewProgressAndSkipsDuplicates() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let original = try ModelContainer(for: VocabWord.self, configurations: configuration)
        let sourceContext = original.mainContext
        let word = VocabWord(term: "context", chineseMeaning: "语境", englishMeaning: "surrounding words",
                             example: "Learn words in context.", note: "work reading", reviewStage: 2, reviewCount: 5)
        sourceContext.insert(word)
        try sourceContext.save()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LexiNote-backup-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try BackupService().exportWords(sourceContext, to: url)

        let restored = try ModelContainer(for: VocabWord.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let targetContext = restored.mainContext
        let first = try BackupService().importWords(from: url, into: targetContext)
        XCTAssertEqual(first.imported, 1)
        let second = try BackupService().importWords(from: url, into: targetContext)
        XCTAssertEqual(second.skipped, 1)
        let words = try targetContext.fetch(FetchDescriptor<VocabWord>())
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words.first?.chineseMeaning, "语境")
        XCTAssertEqual(words.first?.example, "Learn words in context.")
        XCTAssertEqual(words.first?.reviewStage, 2)
        XCTAssertEqual(words.first?.reviewCount, 5)
        XCTAssertEqual(words.first!.nextReviewAt.timeIntervalSince1970,
                       word.nextReviewAt.timeIntervalSince1970, accuracy: 0.001)
    }

    @MainActor
    func testWordPersistsAfterReopeningStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LexiNote-store-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("words.store")

        do {
            let container = try ModelContainer(for: VocabWord.self,
                                               configurations: ModelConfiguration(url: storeURL))
            let context = container.mainContext
            context.insert(VocabWord(term: "resilience", chineseMeaning: "韧性",
                                     example: "She showed resilience."))
            try context.save()
        }

        let reopened = try ModelContainer(for: VocabWord.self,
                                          configurations: ModelConfiguration(url: storeURL))
        let words = try reopened.mainContext.fetch(FetchDescriptor<VocabWord>())
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words.first?.chineseMeaning, "韧性")
        XCTAssertEqual(words.first?.example, "She showed resilience.")
    }
}

private final class StubDictionaryURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isFallback = request.url?.host == "englishdictionaryapi.com"
        let status = isFallback ? 200 : 503
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isFallback {
            let body = #"{"word":"context","pronunciation":{"ipa":"/ˈkɒn.tɛkst/","audioUrl":null},"partsOfSpeech":[{"partOfSpeech":"noun","senses":[{"definition":"The surrounding text.","example":"Learn words in context."}]}]}"#
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
