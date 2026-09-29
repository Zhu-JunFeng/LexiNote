import SwiftData
import SwiftUI

struct ReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var words: [VocabWord]
    @State private var selectedID: UUID?
    @State private var revealed = false
    @State private var message: String?
    @State private var now = Date()

    private var dueWords: [VocabWord] {
        words.filter { $0.nextReviewAt <= now }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
    }

    private var currentWord: VocabWord? {
        if let selectedID, let match = dueWords.first(where: { $0.id == selectedID }) {
            return match
        }
        return dueWords.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("今日复习")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("还剩 \(dueWords.count) 张")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            Divider()

            if let word = currentWord {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(revealed ? "这次记住了吗？" : "先回想这个词的意思")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Text(word.term)
                            .font(LexiStyle.word(44))
                            .textSelection(.enabled)

                        if !word.example.isEmpty {
                            Text(word.example)
                                .font(.system(size: 17, design: .serif))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Divider()

                        if revealed {
                            VStack(alignment: .leading, spacing: 10) {
                                if !word.chineseMeaning.isEmpty {
                                    Text(word.chineseMeaning)
                                        .font(.title3.weight(.medium))
                                }
                                if !word.englishMeaning.isEmpty {
                                    Text(word.englishMeaning)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                if !word.note.isEmpty {
                                    Label(word.note, systemImage: "note.text")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                            }
                        } else {
                            Text("想好后再显示答案。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(28)
                    .background(LexiStyle.page, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(LexiStyle.rule, lineWidth: 1)
                    }

                    if revealed {
                        HStack(spacing: 12) {
                            ratingButton(.forgot, detail: "10 分钟后", tint: .red, word: word)
                            ratingButton(.unsure, detail: "明天再看", tint: .orange, word: word)
                            ratingButton(.remembered, detail: "延长间隔", tint: LexiStyle.accent, word: word)
                        }
                    } else {
                        Button("显示答案") { revealed = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
                .padding(24)
            } else {
                ContentUnavailableView(
                    "今天复习完成",
                    systemImage: "checkmark.circle.fill",
                    description: Text("有新词到期时，可以从菜单栏回来继续。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 14)
            }
        }
        .background(LexiStyle.canvas)
        .tint(LexiStyle.accent)
        .onAppear { now = .now }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func ratingButton(_ rating: ReviewRating, detail: String, tint: Color, word: VocabWord) -> some View {
        Button { rate(word, as: rating) } label: {
            VStack(spacing: 3) {
                Text(rating.rawValue).font(.callout.weight(.semibold))
                Text(detail).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
            .buttonStyle(.bordered)
            .tint(tint)
            .frame(maxWidth: .infinity)
    }

    private func rate(_ word: VocabWord, as rating: ReviewRating) {
        ReviewScheduler.apply(rating, to: word)
        do {
            try modelContext.save()
            selectedID = nil
            revealed = false
            message = nil
        } catch {
            message = "复习进度保存失败：\(error.localizedDescription)"
        }
    }
}
