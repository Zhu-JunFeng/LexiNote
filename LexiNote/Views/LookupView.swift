import AVFoundation
import SwiftData
import SwiftUI

struct LookupView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var runtime = AppRuntime.shared
    @AppStorage("LexiNote.autoRecordToLibrary") private var autoRecordToLibrary = true
    @FocusState private var searchFocused: Bool

    @State private var searchText = ""
    @State private var entry: DictionaryEntry?
    @State private var chineseMeaning = ""
    @State private var englishMeaning = ""
    @State private var example = ""
    @State private var note = ""
    @State private var isLoading = false
    @State private var message: String?
    @State private var savedWord: VocabWord?
    @State private var originalTerm = ""
    @State private var autoSavedWordID: UUID?
    @State private var player: AVPlayer?
    @State private var speech = AVSpeechSynthesizer()
    @State private var lookupToken = UUID()
    @State private var showingComposer = false
    @State private var showAllSenses = false

    private let dictionary = DictionaryService()

    var body: some View {
        Group {
            if showingComposer {
                saveSheet
            } else {
                lookupPage
            }
        }
        .frame(minWidth: 450, minHeight: 450)
        .tint(LexiStyle.accent)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .lexiFocusLookup)) { _ in
            if !showingComposer { searchFocused = true }
        }
        .onChange(of: runtime.lookupRequest?.id) { _, _ in
            guard let request = runtime.lookupRequest else { return }
            searchText = request.term
            if request.term.isEmpty {
                clearLookup()
            } else {
                Task { await lookup(openComposerWhenMissing: request.openComposerWhenMissing) }
            }
        }
        .onChange(of: runtime.saveShortcutID) { _, _ in
            guard runtime.page == .lookup else { return }
            if showingComposer { saveOrEdit() } else { quickSave() }
        }
        .onChange(of: runtime.escapeShortcutID) { _, _ in
            guard runtime.page == .lookup else { return }
            if showingComposer {
                showingComposer = false
            } else {
                runtime.hide()
            }
        }
    }

    private var lookupPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("输入或粘贴英文单词、短语", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .onSubmit { Task { await lookup() } }
                if isLoading { ProgressView().controlSize(.small) }
                Button("查询") { Task { await lookup() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.bordered)
                Button("单词本") { runtime.push(.library) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(LexiStyle.accent)
                    .help("打开单词本")
                Button("翻译") { runtime.push(.translation) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(LexiStyle.accent)
                    .help("打开多语言翻译")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(LexiStyle.canvas)

            Divider()

            ScrollView {
                if let entry {
                    resultContent(entry)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 22)
                } else {
                    ContentUnavailableView(
                        "随手查一个词",
                        systemImage: "character.book.closed",
                        description: Text("输入单词或短语，按回车查看释义。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
            .background(LexiStyle.page)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if entry != nil { lookupFooter }
        }
    }

    @ViewBuilder
    private func resultContent(_ result: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.term)
                        .font(LexiStyle.word(36))
                        .textSelection(.enabled)
                    if let phonetic = result.phonetic, !phonetic.isEmpty {
                        Text(phonetic)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button {
                    pronounce(result)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .help("播放发音")
            }

            if !originalTerm.isEmpty,
               VocabWord.normalize(originalTerm) != VocabWord.normalize(result.term) {
                Text("由“\(originalTerm)”查到原形“\(result.term)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let savedWord {
                Button {
                    runtime.push(.word(savedWord.id))
                } label: {
                    Label("已收藏 · 查看词卡", systemImage: "bookmark.fill")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LexiStyle.accent)
            } else {
                Text("选好这次想记住的意思，再保存到单词本。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !result.chineseDefinitions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("中文释义")
                    ForEach(result.chineseDefinitions, id: \.self) { definition in
                        choiceButton(definition, selected: chineseMeaning == definition) {
                            chineseMeaning = definition
                        }
                    }
                }
            }

            if !result.englishSenses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("英文解释")
                    ForEach(Array(result.englishSenses.prefix(showAllSenses ? result.englishSenses.count : 3))) { sense in
                        let label = [sense.partOfSpeech, sense.englishDefinition]
                            .compactMap { $0 }.joined(separator: " · ")
                        VStack(alignment: .leading, spacing: 3) {
                            choiceButton(label, selected: englishMeaning == sense.englishDefinition) {
                                englishMeaning = sense.englishDefinition
                            }
                            if let sample = sense.example, !sample.isEmpty {
                                Text(sample)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 34)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if result.englishSenses.count > 3 {
                        Button(showAllSenses ? "收起其他释义" : "查看全部 \(result.englishSenses.count) 条释义") {
                            showAllSenses.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(LexiStyle.accent)
                        .padding(.leading, 12)
                        .padding(.top, 6)
                    }
                }
            }

            if result.chineseDefinitions.isEmpty && result.englishSenses.isEmpty {
                Label("词典中暂未找到释义，可以手动填写并收藏。", systemImage: "pencil.line")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let source = result.onlineSource {
                Text("英文释义来源：\(source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lookupFooter: some View {
        HStack(spacing: 12) {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(savedWord == nil ? "释义与原句会一起保存" : "这个词已经在单词本中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button(savedWord == nil ? "保存词卡…" : "编辑词卡") {
                if let savedWord {
                    runtime.push(.word(savedWord.id))
                } else {
                    message = nil
                    showingComposer = true
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(LexiStyle.canvas)
        .overlay(alignment: .top) { LexiStyle.rule.frame(height: 1) }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showingComposer = false
            } label: {
                Label("返回查词", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(LexiStyle.accent)
            .padding(.horizontal, 22)
            .padding(.top, 18)

            HStack(alignment: .firstTextBaseline) {
                Text("保存词卡")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let entry {
                    Text(entry.term)
                        .font(LexiStyle.word(24))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("保存这次遇到的意思，也可以补上原句。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    draftField("中文释义", text: $chineseMeaning, prompt: "可手动填写")
                    draftField("英文解释", text: $englishMeaning, prompt: "可手动填写")
                    draftField("遇到它时的原句", text: $example, prompt: "可选")
                    draftField("自己的笔记", text: $note, prompt: "可选")
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("取消") { showingComposer = false }
                Button("加入单词本") { saveOrEdit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LexiStyle.page)
        .tint(LexiStyle.accent)
    }

    private func draftField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.callout.weight(.medium))
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
            LexiStyle.rule.frame(height: 1)
        }
        .padding(.bottom, 3)
    }

    private func choiceButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? LexiStyle.accent : Color.secondary)
                Text(title)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            .padding(10)
            .background(selected ? LexiStyle.softAccent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func lookup(openComposerWhenMissing: Bool = false) async {
        let query = VocabWord.clean(searchText)
        guard !query.isEmpty else { return }
        let token = UUID()
        lookupToken = token
        message = nil
        showingComposer = false
        showAllSenses = false
        entry = nil
        chineseMeaning = ""
        englishMeaning = ""
        example = ""
        note = ""
        originalTerm = query
        autoSavedWordID = nil
        savedWord = findWord(query)
        let preferred = await dictionary.preferredTerm(for: query)
        guard lookupToken == token else { return }
        savedWord = savedWord ?? findWord(preferred)
        let key = VocabWord.normalize(preferred)
        let local = await dictionary.localEntry(term: preferred)
        guard lookupToken == token else { return }
        if local.hasDefinition {
            setEntry(local)
            autoRecord(local)
        }
        var cachedEntry: DictionaryEntry?
        if let cache = findCache(key),
           let decoded = try? JSONDecoder().decode(DictionaryEntry.self, from: cache.entryData) {
            cachedEntry = decoded
            setEntry(decoded)
            autoRecord(decoded)
        }

        isLoading = true
        let fresh = await dictionary.lookupResolved(original: query, preferred: preferred)
        guard lookupToken == token else { return }
        isLoading = false
        if fresh.wasFetchedOnline || cachedEntry == nil {
            savedWord = savedWord ?? findWord(fresh.term)
            let oldEntry = entry
            let preserveDraft = oldEntry != nil && (
                chineseMeaning != (oldEntry?.chineseDefinitions.first ?? "") ||
                englishMeaning != (oldEntry?.englishSenses.first?.englishDefinition ?? "") ||
                !example.isEmpty ||
                note != (savedWord?.note ?? "")
            )
            let draft = (chineseMeaning, englishMeaning, example, note)
            setEntry(fresh)
            if preserveDraft {
                (chineseMeaning, englishMeaning, example, note) = draft
            }
            if fresh.hasDefinition {
                cacheEntry(fresh, key: VocabWord.normalize(fresh.term))
                autoRecord(fresh)
            }
            if !fresh.wasFetchedOnline && fresh.hasDefinition && message == nil {
                message = "当前显示本地词典释义。"
            }
        } else if cachedEntry != nil {
            if message == nil { message = "网络不可用，正在显示已缓存的释义。" }
        }
        if openComposerWhenMissing && entry?.hasDefinition == false {
            showingComposer = true
        }
    }

    private func clearLookup() {
        lookupToken = UUID()
        isLoading = false
        entry = nil
        chineseMeaning = ""
        englishMeaning = ""
        example = ""
        note = ""
        originalTerm = ""
        savedWord = nil
        autoSavedWordID = nil
        message = nil
        showingComposer = false
        searchFocused = true
    }

    private func autoRecord(_ value: DictionaryEntry) {
        guard autoRecordToLibrary, value.hasDefinition else { return }
        if let existing = savedWord ?? findWord(originalTerm) ?? findWord(value.term) {
            savedWord = existing
            guard autoSavedWordID == existing.id else { return }
            var changed = false
            if existing.chineseMeaning.isEmpty, let meaning = value.chineseDefinitions.first {
                existing.chineseMeaning = meaning
                changed = true
            }
            if existing.englishMeaning.isEmpty, let meaning = value.englishSenses.first?.englishDefinition {
                existing.englishMeaning = meaning
                changed = true
            }
            if existing.phonetic.isEmpty, let phonetic = value.phonetic {
                existing.phonetic = phonetic
                changed = true
            }
            if changed { try? modelContext.save() }
            return
        }
        let word = VocabWord(
            term: value.term,
            chineseMeaning: value.chineseDefinitions.first ?? "",
            englishMeaning: value.englishSenses.first?.englishDefinition ?? "",
            phonetic: value.phonetic ?? ""
        )
        modelContext.insert(word)
        do {
            try modelContext.save()
            savedWord = word
            autoSavedWordID = word.id
            message = "已自动加入单词本，可继续编辑。"
        } catch {
            modelContext.delete(word)
            message = "自动收藏失败：\(error.localizedDescription)"
        }
    }

    private func quickSave() {
        if let savedWord {
            runtime.push(.word(savedWord.id))
            return
        }
        guard let entry else {
            message = "请先查询单词。"
            return
        }
        if entry.hasDefinition {
            saveOrEdit()
        } else {
            showingComposer = true
        }
    }

    private func setEntry(_ value: DictionaryEntry) {
        entry = value
        chineseMeaning = value.chineseDefinitions.first ?? ""
        englishMeaning = value.englishSenses.first?.englishDefinition ?? ""
        example = ""
        note = savedWord?.note ?? ""
    }

    private func findWord(_ term: String) -> VocabWord? {
        let key = VocabWord.normalize(term)
        let descriptor = FetchDescriptor<VocabWord>(predicate: #Predicate { $0.normalizedTerm == key })
        return try? modelContext.fetch(descriptor).first
    }

    private func findCache(_ key: String) -> LookupCache? {
        let descriptor = FetchDescriptor<LookupCache>(predicate: #Predicate { $0.normalizedTerm == key })
        return try? modelContext.fetch(descriptor).first
    }

    private func cacheEntry(_ value: DictionaryEntry, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if let cache = findCache(key) {
            cache.entryData = data
            cache.fetchedAt = .now
        } else {
            modelContext.insert(LookupCache(normalizedTerm: key, entryData: data))
        }
        try? modelContext.save()
    }

    private func saveOrEdit() {
        guard let entry else { return }
        if let existing = findWord(originalTerm) ?? findWord(entry.term) {
            savedWord = existing
            showingComposer = false
            runtime.push(.word(existing.id))
            message = "这个词已经收藏，已打开原词卡。"
            return
        }
        guard !chineseMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
              !englishMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请先填写中文或英文释义。"
            return
        }
        let word = VocabWord(
            term: entry.term,
            chineseMeaning: chineseMeaning.trimmingCharacters(in: .whitespacesAndNewlines),
            englishMeaning: englishMeaning.trimmingCharacters(in: .whitespacesAndNewlines),
            phonetic: entry.phonetic ?? "",
            example: example.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(word)
        do {
            try modelContext.save()
            savedWord = word
            message = "已加入单词本，明天开始复习。"
            showingComposer = false
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    private func pronounce(_ value: DictionaryEntry) {
        if let url = value.audioURL {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            let utterance = AVSpeechUtterance(string: value.term)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.48
            speech.speak(utterance)
        }
    }
}
