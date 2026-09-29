import SwiftData
import SwiftUI

/// A recommendation is deliberately a preview: merely opening its notification never saves it.
struct RecommendationView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var runtime = AppRuntime.shared
    let term: String

    @State private var entry: DictionaryEntry?
    @State private var isLoading = false
    @State private var message: String?
    private let dictionary = DictionaryService()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日推荐")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("预览 · 尚未收藏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(entry?.term ?? term)
                        .font(LexiStyle.word(42))
                    if let phonetic = entry?.phonetic, !phonetic.isEmpty {
                        Text(phonetic).foregroundStyle(.secondary)
                    }
                    if isLoading { ProgressView("正在查询释义…") }
                    if let entry {
                        if let chinese = entry.chineseDefinitions.first {
                            Text(chinese).font(.title3)
                        }
                        if let english = entry.englishSenses.first?.englishDefinition {
                            Text(english).font(.callout).foregroundStyle(.secondary)
                        }
                        if let sample = entry.englishSenses.first?.example {
                            Text(sample).font(.system(size: 16, design: .serif))
                        }
                        if !entry.hasDefinition {
                            Text("暂未找到释义，可以从查词页手动填写。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let message { Text(message).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("加入单词本") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(entry?.hasDefinition != true)
            }
        }
        .padding(24)
        .background(LexiStyle.page)
        .task(id: term) { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        let local = await dictionary.localEntry(term: term)
        entry = local
        if !local.hasDefinition {
            entry = await dictionary.lookup(term: term)
        }
        isLoading = false
    }

    private func save() {
        guard let entry, entry.hasDefinition else { return }
        let key = VocabWord.normalize(entry.term)
        let descriptor = FetchDescriptor<VocabWord>(predicate: #Predicate { $0.normalizedTerm == key })
        if let existing = try? modelContext.fetch(descriptor).first {
            runtime.open(.word(existing.id))
            return
        }
        let word = VocabWord(term: entry.term,
                             chineseMeaning: entry.chineseDefinitions.first ?? "",
                             englishMeaning: entry.englishSenses.first?.englishDefinition ?? "",
                             phonetic: entry.phonetic ?? "")
        modelContext.insert(word)
        do {
            try modelContext.save()
            runtime.open(.word(word.id))
        } catch {
            modelContext.delete(word)
            message = "收藏失败：\(error.localizedDescription)"
        }
    }
}
