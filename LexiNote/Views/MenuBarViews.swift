import AppKit
import SwiftData
import SwiftUI

struct MenuBarLabelView: View {
    @Query private var words: [VocabWord]
    @State private var now = Date()

    var body: some View {
        HStack(spacing: 4) {
            Image("MenuBarGlyph")
                .renderingMode(.template)
                .interpolation(.high)
            let dueCount = words.filter { $0.nextReviewAt <= now }.count
            if dueCount > 0 {
                Text("\(dueCount)")
                    .font(.caption2.monospacedDigit())
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}

struct MenuBarContentView: View {
    @Query private var words: [VocabWord]

    private var dueCount: Int {
        words.filter { $0.nextReviewAt <= .now }.count
    }

    var body: some View {
        Button("查单词") {
            AppRuntime.shared.showLookup()
        }
        Button("单词本") {
            AppRuntime.shared.open(.library)
        }
        Button("今日复习（\(dueCount)）") {
            AppRuntime.shared.open(.review)
        }
        Divider()
        Button("偏好设置…") {
            AppRuntime.shared.open(.preferences)
        }
        Button("退出 LexiNote") {
            NSApp.terminate(nil)
        }
    }
}
