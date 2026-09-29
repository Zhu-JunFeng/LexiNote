import SwiftData
import SwiftUI

struct AppShellView: View {
    @ObservedObject private var runtime = AppRuntime.shared
    @Query private var words: [VocabWord]

    var body: some View {
        ZStack {
            // Keep the lookup view mounted so a return from another page restores its draft.
            LookupView()
                .opacity(runtime.page == .lookup ? 1 : 0)
                .disabled(runtime.page != .lookup)
                .accessibilityHidden(runtime.page != .lookup)

            if runtime.page != .lookup {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            runtime.backOrHide()
                        } label: {
                            Label("返回", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LexiStyle.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                    Divider()

                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(LexiStyle.canvas)
            }
        }
        .tint(LexiStyle.accent)
        .environment(\.timeZone, BeijingTime.timeZone)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch runtime.page {
        case .lookup:
            EmptyView()
        case .library:
            LibraryView()
        case .review:
            ReviewView()
        case .preferences:
            SettingsView()
        case .word(let id):
            if let word = words.first(where: { $0.id == id }) {
                WordEditorView(word: word)
            } else {
                ContentUnavailableView("找不到这张词卡", systemImage: "questionmark.square.dashed")
            }
        case .recommendation(let term):
            RecommendationView(term: term)
        }
    }
}
