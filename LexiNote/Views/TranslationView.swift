import AppKit
import SwiftUI
import Translation

/// Translation is separate from vocabulary lookup: a sentence must never be
/// automatically added to the English word book.
struct TranslationView: View {
    var body: some View {
        if #available(macOS 15, *) {
            SystemTranslationView()
        } else {
            ContentUnavailableView(
                "需要 macOS 15 或更新版本",
                systemImage: "translate",
                description: Text("系统多语言翻译需要 macOS 15；原有英语查词仍可使用。")
            )
        }
    }
}

@available(macOS 15, *)
private struct SystemTranslationView: View {
    @AppStorage("LexiNote.translationSource") private var sourceCode = "auto"
    @AppStorage("LexiNote.translationTarget") private var targetCode = "zh"
    @State private var sourceText = ""
    @State private var translatedText = ""
    @State private var errorMessage: String?
    @State private var isTranslating = false
    @State private var pendingText = ""
    @State private var requestID = UUID()
    @State private var configuration: TranslationSession.Configuration?

    private let maxCharacters = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("多语言翻译")
                        .font(.title2.weight(.semibold))
                    Text("翻译词语或短句，译文不会自动加入英语单词本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("方言词典") { AppRuntime.shared.push(.dialectDictionary) }
                    .buttonStyle(.plain)
                    .foregroundStyle(LexiStyle.accent)
            }

            HStack(spacing: 10) {
                Picker("源语言", selection: $sourceCode) {
                    Text("自动识别").tag("auto")
                    ForEach(TranslationLanguage.common) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .frame(maxWidth: .infinity)
                Button {
                    guard sourceCode != "auto" else { return }
                    (sourceCode, targetCode) = (targetCode, sourceCode)
                    (sourceText, translatedText) = (translatedText, sourceText)
                    configuration = nil
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("交换语言与文本")
                .disabled(sourceCode == "auto" || translatedText.isEmpty)
                Picker("目标语言", selection: $targetCode) {
                    ForEach(TranslationLanguage.common) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(alignment: .top, spacing: 14) {
                textPanel(title: "原文", text: $sourceText, isEditable: true)
                textPanel(title: "译文", text: $translatedText, isEditable: false)
            }

            HStack {
                Text("系统翻译在设备上运行；首次使用某种语言时，macOS 可能询问是否下载语言包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(sourceText.count)/\(maxCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(sourceText.count > maxCharacters ? .red : .secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if isTranslating { ProgressView("正在翻译…").controlSize(.small) }
                Spacer()
                Button("复制译文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translatedText, forType: .string)
                }
                .disabled(translatedText.isEmpty)
                Button("翻译") { translate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTranslating || sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background(LexiStyle.page)
        .translationTask(configuration) { session in
            let text = pendingText
            let id = requestID
            do {
                let response = try await session.translate(text)
                guard id == requestID else { return }
                translatedText = response.targetText
                isTranslating = false
            } catch {
                guard id == requestID else { return }
                errorMessage = "翻译失败：\(error.localizedDescription)"
                isTranslating = false
            }
        }
        .onChange(of: sourceCode) { _, _ in resetResult() }
        .onChange(of: targetCode) { _, _ in resetResult() }
        .onChange(of: sourceText) { _, _ in resetResult() }
    }

    private func textPanel(title: String, text: Binding<String>, isEditable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.callout.weight(.semibold))
            if isEditable {
                TextEditor(text: text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(LexiStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(LexiStyle.rule))
            } else {
                ScrollView {
                    Text(text.wrappedValue.isEmpty ? "译文会显示在这里" : text.wrappedValue)
                        .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(LexiStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(LexiStyle.rule))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= maxCharacters else {
            errorMessage = "一次最多翻译 \(maxCharacters) 个字符。"
            return
        }
        guard sourceCode == "auto" || sourceCode != targetCode else {
            errorMessage = "请选择不同的源语言和目标语言。"
            return
        }
        guard let target = TranslationLanguage.common.first(where: { $0.code == targetCode }) else { return }
        let source = TranslationLanguage.common.first(where: { $0.code == sourceCode })
        errorMessage = nil
        translatedText = ""
        pendingText = text
        requestID = UUID()
        isTranslating = true
        let from = source.map { Locale.Language(identifier: $0.code) }
        let to = Locale.Language(identifier: target.code)
        if configuration?.source == from && configuration?.target == to {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: from, target: to)
        }
    }

    private func resetResult() {
        requestID = UUID()
        isTranslating = false
        translatedText = ""
        errorMessage = nil
        configuration = nil
    }
}

struct TranslationLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let common: [Self] = [
        .init(code: "zh", name: "简体中文"),
        .init(code: "zh-TW", name: "繁体中文"),
        .init(code: "en", name: "英语"),
        .init(code: "ja", name: "日语"),
        .init(code: "ko", name: "韩语"),
        .init(code: "fr", name: "法语"),
        .init(code: "de", name: "德语"),
        .init(code: "es", name: "西班牙语"),
        .init(code: "it", name: "意大利语"),
        .init(code: "pt", name: "葡萄牙语"),
        .init(code: "ru", name: "俄语"),
        .init(code: "vi", name: "越南语")
    ]
}
