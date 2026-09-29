import Foundation
import NaturalLanguage
import SQLite3

/// One English definition returned by Free Dictionary API or the offline ECDICT data.
struct DictionarySense: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let partOfSpeech: String?
    let englishDefinition: String
    let example: String?
}

/// A lookup result. Empty definitions mean the term was not found and can be entered manually.
struct DictionaryEntry: Codable, Hashable, Sendable {
    let term: String
    let chineseDefinitions: [String]
    let englishSenses: [DictionarySense]
    let phonetic: String?
    let audioURL: URL?
    let isFromLocalDictionary: Bool
    let wasFetchedOnline: Bool
    let onlineSource: String?

    init(
        term: String,
        chineseDefinitions: [String],
        englishSenses: [DictionarySense],
        phonetic: String?,
        audioURL: URL?,
        isFromLocalDictionary: Bool,
        wasFetchedOnline: Bool = false,
        onlineSource: String? = nil
    ) {
        self.term = term
        self.chineseDefinitions = chineseDefinitions
        self.englishSenses = englishSenses
        self.phonetic = phonetic
        self.audioURL = audioURL
        self.isFromLocalDictionary = isFromLocalDictionary
        self.wasFetchedOnline = wasFetchedOnline
        self.onlineSource = onlineSource
    }

    var hasDefinition: Bool {
        !chineseDefinitions.isEmpty || !englishSenses.isEmpty
    }
}

/// Combines the bundled, read-only ECDICT database with optional online English data.
/// Network errors and missing dictionary fields never prevent a lookup result.
actor DictionaryService {
    private let databaseURL: URL?
    private let session: URLSession
    private var onlineCache: [String: DictionaryEntry] = [:]

    /// Pass `databaseURL` or `session` in tests. The production database is `ecdict.sqlite`
    /// in the app bundle's Resources directory.
    init(bundle: Bundle = .main, databaseURL: URL? = nil, session: URLSession? = nil) {
        self.databaseURL = databaseURL ?? bundle.url(forResource: "ecdict", withExtension: "sqlite")
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Returns bundled definitions immediately, without waiting for the network.
    func localEntry(term rawTerm: String) -> DictionaryEntry {
        let term = rawTerm.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let local = lookupLocal(key: term.lowercased())
        return DictionaryEntry(
            term: local?.word ?? term,
            chineseDefinitions: local?.chineseDefinitions ?? [],
            englishSenses: local?.englishDefinitions.enumerated().map { index, definition in
                DictionarySense(id: "ecdict-\(index)", partOfSpeech: nil,
                                englishDefinition: definition, example: nil)
            } ?? [],
            phonetic: local?.phonetic,
            audioURL: nil,
            isFromLocalDictionary: local != nil
        )
    }

    /// Prefer a known base form for one word; preserve exact idiomatic phrases.
    func preferredTerm(for rawTerm: String) -> String {
        let term = rawTerm.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if term.contains(" ") { return term }
        guard let lemma = TermLemmatizer.candidate(for: term), lemma.lowercased() != term.lowercased() else {
            return term
        }
        let lemmaExists = lookupLocal(key: lemma.lowercased()) != nil
        return lemmaExists ? lemma : term
    }

    /// Try the original phrase first; a lemma is a fallback when no dictionary knows it.
    func lookupResolved(original: String, preferred: String) async -> DictionaryEntry {
        let first = await lookup(term: preferred)
        guard !first.hasDefinition,
              let lemma = TermLemmatizer.candidate(for: original),
              lemma.lowercased() != preferred.lowercased() else { return first }
        let fallback = await lookup(term: lemma)
        return fallback.hasDefinition ? fallback : first
    }

    func lookup(term rawTerm: String) async -> DictionaryEntry {
        let term = rawTerm.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !term.isEmpty else {
            return DictionaryEntry(
                term: "", chineseDefinitions: [], englishSenses: [],
                phonetic: nil, audioURL: nil, isFromLocalDictionary: false
            )
        }

        let key = term.lowercased()
        if let cached = onlineCache[key] {
            return cached
        }

        let local = lookupLocal(key: key)
        let online = await lookupOnline(key: key)
        let senses: [DictionarySense]
        if let online, !online.senses.isEmpty {
            senses = online.senses
        } else {
            senses = local?.englishDefinitions.enumerated().map { index, definition in
                DictionarySense(
                    id: "ecdict-\(index)", partOfSpeech: nil,
                    englishDefinition: definition, example: nil
                )
            } ?? []
        }

        let entry = DictionaryEntry(
            term: online?.word ?? local?.word ?? term,
            chineseDefinitions: local?.chineseDefinitions ?? [],
            englishSenses: senses,
            phonetic: online?.phonetic ?? local?.phonetic,
            audioURL: online?.audioURL,
            isFromLocalDictionary: local != nil,
            wasFetchedOnline: online != nil,
            onlineSource: online?.sourceName
        )

        // Cache successful online results. A network failure may be temporary, so keep
        // retrying on later lookups while still returning local data immediately.
        if online != nil {
            onlineCache[key] = entry
        }
        return entry
    }

    private func lookupLocal(key: String) -> LocalEntry? {
        guard let databaseURL else { return nil }

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            if connection != nil { sqlite3_close(connection) }
            return nil
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        let query = "SELECT word, phonetic, definition, translation FROM entries WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if statement != nil { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        return key.withCString { keyBytes in
            // SQLITE_STATIC is safe because stepping and reading happen before this closure ends.
            sqlite3_bind_text(statement, 1, keyBytes, -1, nil)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let word = columnText(statement, 0) else { return nil }
            return LocalEntry(
                word: word,
                phonetic: columnText(statement, 1).flatMap(nonempty),
                englishDefinitions: splitDefinitions(columnText(statement, 2)),
                chineseDefinitions: splitDefinitions(columnText(statement, 3))
            )
        }
    }

    private func lookupOnline(key: String) async -> OnlineEntry? {
        if let primary = await lookupFreeDictionary(key: key), !primary.senses.isEmpty {
            return primary
        }
        return await lookupEnglishDictionary(key: key)
    }

    private func lookupFreeDictionary(key: String) async -> OnlineEntry? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let responses = try? JSONDecoder().decode([APIEntry].self, from: data),
                  !responses.isEmpty else { return nil }

            let definitions = responses.flatMap { entry in
                (entry.meanings ?? []).flatMap { meaning in
                    (meaning.definitions ?? []).compactMap { definition -> (String?, String, String?)? in
                        guard let text = definition.definition.flatMap(nonempty) else { return nil }
                        return (meaning.partOfSpeech.flatMap(nonempty), text, definition.example.flatMap(nonempty))
                    }
                }
            }
            let senses = definitions.prefix(16).enumerated().map { index, definition in
                DictionarySense(
                    id: "dictionaryapi-\(index)",
                    partOfSpeech: definition.0,
                    englishDefinition: definition.1,
                    example: definition.2
                )
            }

            let allPhonetics = responses.flatMap { $0.phonetics ?? [] }
            let phonetic = responses.lazy.compactMap { $0.phonetic.flatMap(nonempty) }.first
                ?? allPhonetics.lazy.compactMap { $0.text.flatMap(nonempty) }.first
            let audioURL = allPhonetics.lazy.compactMap { phonetic -> URL? in
                guard let value = phonetic.audio.flatMap(nonempty) else { return nil }
                let resolved = value.hasPrefix("//") ? "https:\(value)" : value
                guard let url = URL(string: resolved), url.scheme == "https" else { return nil }
                return url
            }.first

            return OnlineEntry(
                word: responses.lazy.compactMap { $0.word.flatMap(nonempty) }.first,
                senses: senses,
                phonetic: phonetic,
                audioURL: audioURL,
                sourceName: "Free Dictionary API"
            )
        } catch {
            return nil
        }
    }

    private func lookupEnglishDictionary(key: String) async -> OnlineEntry? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://englishdictionaryapi.com/api/v1/words/\(encoded)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try? JSONDecoder().decode(AlternateAPIEntry.self, from: data) else {
                return nil
            }
            let definitions = (result.partsOfSpeech ?? []).flatMap { part in
                (part.senses ?? []).compactMap { sense -> (String?, String, String?)? in
                    guard let text = sense.definition.flatMap(nonempty) else { return nil }
                    return (part.partOfSpeech.flatMap(nonempty), text, sense.example.flatMap(nonempty))
                }
            }
            let senses = definitions.prefix(16).enumerated().map { index, definition in
                DictionarySense(
                    id: "englishdictionaryapi-\(index)",
                    partOfSpeech: definition.0,
                    englishDefinition: definition.1,
                    example: definition.2
                )
            }
            guard !senses.isEmpty else { return nil }
            let audioURL = result.pronunciation?.audioUrl.flatMap(nonempty).flatMap(URL.init(string:))
            return OnlineEntry(
                word: result.word.flatMap(nonempty),
                senses: senses,
                phonetic: result.pronunciation?.ipa.flatMap(nonempty),
                audioURL: audioURL?.scheme == "https" ? audioURL : nil,
                sourceName: "EnglishDictionaryAPI · Wiktionary"
            )
        } catch {
            return nil
        }
    }
}

enum TermLemmatizer {
    static func candidate(for term: String) -> String? {
        let words = term.split(separator: " ")
        guard !words.isEmpty, words.count <= 6 else { return nil }
        let lemmas = words.map { word -> String in
            let text = String(word)
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = text
            tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
            return tagger.tag(at: text.startIndex, unit: .word, scheme: .lemma).0?.rawValue ?? text
        }
        let result = lemmas.joined(separator: " ")
        return result.lowercased() == term.lowercased() ? nil : result
    }
}

private struct LocalEntry {
    let word: String
    let phonetic: String?
    let englishDefinitions: [String]
    let chineseDefinitions: [String]
}

private struct OnlineEntry {
    let word: String?
    let senses: [DictionarySense]
    let phonetic: String?
    let audioURL: URL?
    let sourceName: String
}

private struct AlternateAPIEntry: Decodable {
    let word: String?
    let pronunciation: AlternatePronunciation?
    let partsOfSpeech: [AlternatePartOfSpeech]?
}

private struct AlternatePronunciation: Decodable {
    let ipa: String?
    let audioUrl: String?
}

private struct AlternatePartOfSpeech: Decodable {
    let partOfSpeech: String?
    let senses: [AlternateSense]?
}

private struct AlternateSense: Decodable {
    let definition: String?
    let example: String?
}

private struct APIEntry: Decodable {
    let word: String?
    let phonetic: String?
    let phonetics: [APIPhonetic]?
    let meanings: [APIMeaning]?
}

private struct APIPhonetic: Decodable {
    let text: String?
    let audio: String?
}

private struct APIMeaning: Decodable {
    let partOfSpeech: String?
    let definitions: [APIDefinition]?
}

private struct APIDefinition: Decodable {
    let definition: String?
    let example: String?
}

private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let bytes = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: UnsafeRawPointer(bytes).assumingMemoryBound(to: CChar.self))
}

private func nonempty(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func splitDefinitions(_ text: String?) -> [String] {
    guard let text else { return [] }
    // ECDICT encodes line breaks as literal backslash-n sequences inside CSV cells.
    return text.replacingOccurrences(of: "\\n", with: "\n")
        .components(separatedBy: .newlines)
        .compactMap(nonempty)
        .prefix(16)
        .map { $0 }
}
