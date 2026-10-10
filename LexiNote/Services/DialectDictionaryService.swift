import Foundation

enum Dialect: String, CaseIterable, Identifiable {
    case cantonese
    case taiwaneseHokkien

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cantonese: "粤语 → 英语"
        case .taiwaneseHokkien: "闽南语（台语）→ 华语"
        }
    }
    var sourceName: String {
        switch self {
        case .cantonese: "CC-Canto"
        case .taiwaneseHokkien: "萌典 · 教育部臺灣台語常用詞辭典"
        }
    }
}

struct DialectEntry: Equatable {
    let term: String
    let pronunciation: String?
    let definitions: [String]
    let sourceName: String
    let sourceURL: URL
}

/// Exact word or short-phrase lookup. This deliberately does not present
/// dictionary glosses as full-sentence machine translations.
actor DialectDictionaryService {
    private let cantoneseURL: URL?
    private let session: URLSession
    private var cantoneseIndex: [String: DialectEntry]?

    init(bundle: Bundle = .main, cantoneseURL: URL? = nil, session: URLSession? = nil) {
        self.cantoneseURL = cantoneseURL ?? bundle.url(forResource: "cccanto", withExtension: "txt")
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    func lookup(_ rawTerm: String, dialect: Dialect) async -> DialectEntry? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 24, !term.contains("\n") else { return nil }
        switch dialect {
        case .cantonese:
            if cantoneseIndex == nil { cantoneseIndex = Self.loadCantonese(at: cantoneseURL) }
            return cantoneseIndex?[term]
        case .taiwaneseHokkien:
            return await lookupHokkien(term)
        }
    }

    private static func loadCantonese(at url: URL?) -> [String: DialectEntry] {
        guard let url, let content = try? String(contentsOf: url, encoding: .utf8),
              let pattern = try? NSRegularExpression(
                pattern: #"^(.+?) (.+?) \[[^]]*\] \{([^}]*)\} /(.+)/$"#
              ) else { return [:] }
        var index: [String: DialectEntry] = [:]
        let sourceURL = URL(string: "https://cc-canto.org/")!
        for line in content.split(separator: "\n") where !line.hasPrefix("#") {
            let text = String(line)
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = pattern.firstMatch(in: text, range: fullRange),
                  let traditional = match.substring(at: 1, in: text),
                  let simplified = match.substring(at: 2, in: text),
                  let reading = match.substring(at: 3, in: text),
                  let glosses = match.substring(at: 4, in: text) else { continue }
            let definitions = glosses.split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(5)
                .map { $0 }
            guard !definitions.isEmpty else { continue }
            let entry = DialectEntry(term: traditional, pronunciation: reading,
                                     definitions: definitions, sourceName: "CC-Canto",
                                     sourceURL: sourceURL)
            index[traditional] = entry
            index[simplified] = entry
        }
        return index
    }

    private func lookupHokkien(_ term: String) async -> DialectEntry? {
        let allowed = CharacterSet.alphanumerics
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://www.moedict.tw/t/\(encoded).json") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let record = try? JSONDecoder().decode(MoeDictEntry.self, from: data),
                  !record.heteronyms.isEmpty else { return nil }
            let definitions = record.heteronyms.flatMap(\.definitions)
                .compactMap { $0.meaning?.replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "~", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(6)
                .map { $0 }
            guard !definitions.isEmpty else { return nil }
            return DialectEntry(
                term: term,
                pronunciation: record.heteronyms.first?.pronunciation,
                definitions: definitions,
                sourceName: Dialect.taiwaneseHokkien.sourceName,
                sourceURL: URL(string: "https://www.moedict.tw/t/\(encoded)")!
            )
        } catch {
            return nil
        }
    }
}

private extension NSTextCheckingResult {
    func substring(at index: Int, in text: String) -> String? {
        guard let range = Range(self.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

private struct MoeDictEntry: Decodable {
    let heteronyms: [MoeDictHeteronym]
    enum CodingKeys: String, CodingKey { case heteronyms = "h" }
}

private struct MoeDictHeteronym: Decodable {
    let pronunciation: String?
    let definitions: [MoeDictDefinition]
    enum CodingKeys: String, CodingKey { case pronunciation = "T", definitions = "d" }
}

private struct MoeDictDefinition: Decodable {
    let meaning: String?
    enum CodingKeys: String, CodingKey { case meaning = "f" }
}
