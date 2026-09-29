import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabWord.createdAt, order: .reverse) private var words: [VocabWord]
    @State private var searchText = ""
    @State private var selectedWord: VocabWord?
    @State private var message: String?
    @State private var showDeleteConfirmation = false

    private var filteredWords: [VocabWord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return words }
        return words.filter {
            $0.term.localizedCaseInsensitiveContains(query) ||
            $0.chineseMeaning.localizedCaseInsensitiveContains(query) ||
            $0.note.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("单词本")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(words.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)

                if words.isEmpty {
                    ContentUnavailableView(
                        "还没有词卡",
                        systemImage: "character.book.closed",
                        description: Text("按快捷键查词，保存想记住的释义与原句。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredWords.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredWords, selection: $selectedWord) { word in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(word.term)
                                .font(LexiStyle.word(20))
                                .lineLimit(1)
                            Text(word.chineseMeaning.isEmpty ? word.englishMeaning : word.chineseMeaning)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .tag(word)
                    }
                    .listStyle(.sidebar)
                }

                Divider()
                Text("保存遇到它时的意思")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .searchable(text: $searchText, prompt: "搜索单词、释义或笔记")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let selectedWord {
                WordEditorView(word: selectedWord)
                    .toolbar {
                        Button("删除词卡", systemImage: "trash", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
            } else {
                ContentUnavailableView(
                    "选择一张词卡",
                    systemImage: "character.book.closed",
                    description: Text("这里可以修改释义、原句与笔记。")
                )
            }
        }
        .tint(LexiStyle.accent)
        .toolbar {
            ToolbarItemGroup {
                Button("导入 JSON", systemImage: "square.and.arrow.down") { importBackup() }
                Button("导出 JSON", systemImage: "square.and.arrow.up") { exportBackup() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.bar)
            }
        }
        .confirmationDialog("删除“\(selectedWord?.term ?? "")”？", isPresented: $showDeleteConfirmation) {
            Button("删除词卡", role: .destructive) { deleteSelected() }
        } message: {
            Text("此操作也会删除它的复习进度。")
        }
    }

    private func deleteSelected() {
        guard let selectedWord else { return }
        modelContext.delete(selectedWord)
        do {
            try modelContext.save()
            self.selectedWord = nil
            message = "词卡已删除。"
        } catch {
            message = "删除失败：\(error.localizedDescription)"
        }
    }

    private func exportBackup() {
        do {
            if let url = try BackupService().exportWords(modelContext) {
                message = "已导出到 \(url.lastPathComponent)"
            }
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func importBackup() {
        do {
            if let summary = try BackupService().importWords(into: modelContext) {
                message = "导入 \(summary.imported) 张，跳过重复 \(summary.skipped) 张。"
            }
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }
}

struct WordEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var runtime = AppRuntime.shared
    @Bindable var word: VocabWord
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(word.term)
                        .font(LexiStyle.word(38))
                        .textSelection(.enabled)
                    if !word.phonetic.isEmpty {
                        Text(word.phonetic)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    editorField("中文释义", text: $word.chineseMeaning)
                    editorField("英文解释", text: $word.englishMeaning)
                    editorField("遇到它时的原句", text: $word.example)
                    editorField("自己的笔记", text: $word.note)
                }

                Divider()
                HStack(spacing: 22) {
                    Label {
                        Text(word.nextReviewAt, style: .date)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    Label("已复习 \(word.reviewCount) 次", systemImage: "checkmark.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .background(LexiStyle.page)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存修改") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(LexiStyle.canvas)
            .overlay(alignment: .top) { LexiStyle.rule.frame(height: 1) }
        }
        .tint(LexiStyle.accent)
        .onChange(of: runtime.saveShortcutID) { _, _ in
            if runtime.page == .library || runtime.page == .word(word.id) {
                save()
            }
        }
    }

    private func editorField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.callout.weight(.medium))
            TextField(title, text: text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        word.updatedAt = .now
        do {
            try modelContext.save()
            message = "已保存。"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}
