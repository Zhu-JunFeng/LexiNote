import AppKit
import SwiftUI

struct DialectDictionaryView: View {
    @State private var dialect: Dialect = .cantonese
    @State private var searchText = ""
    @State private var entry: DialectEntry?
    @State private var isLoading = false
    @State private var message: String?
    @State private var requestID = UUID()
    private let dictionary = DialectDictionaryService()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("方言词典")
                    .font(.title2.weight(.semibold))
                Text("查粤语或闽南语的词语与短语。词典解释不等于整句机器翻译。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Picker("词典", selection: $dialect) {
                    ForEach(Dialect.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(maxWidth: 280)
                TextField("输入方言词语，例如「唔該」或「食」", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await lookup() } }
                Button("查询") { Task { await lookup() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isLoading { ProgressView("正在查词…").controlSize(.small) }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(entry.term).font(LexiStyle.word(34))
                        if let pronunciation = entry.pronunciation {
                            Text(pronunciation).foregroundStyle(.secondary)
                        }
                        ForEach(entry.definitions, id: \.self) { definition in
                            Text(definition)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                                .background(LexiStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                                .textSelection(.enabled)
                        }
                        Link("来源：\(entry.sourceName)", destination: entry.sourceURL)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !isLoading && message == nil {
                ContentUnavailableView("从一个词开始", systemImage: "character.book.closed",
                                       description: Text("粤语词条离线可查；闽南语词条需要联网。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(LexiStyle.page)
        .onChange(of: dialect) { _, _ in
            requestID = UUID()
            entry = nil
            message = nil
            isLoading = false
        }
    }

    @MainActor
    private func lookup() async {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard term.count <= 24, !term.contains("\n") else {
            message = "请输入不超过 24 个字符的词语或短语。"
            return
        }
        let id = UUID()
        requestID = id
        entry = nil
        message = nil
        isLoading = true
        let result = await dictionary.lookup(term, dialect: dialect)
        guard id == requestID else { return }
        isLoading = false
        entry = result
        if result == nil {
            message = dialect == .cantonese
                ? "CC-Canto 未收录这个词；它只包含部分粤语特有词义。"
                : "没有找到闽南语词条，请检查写法或网络连接。"
        }
    }
}
