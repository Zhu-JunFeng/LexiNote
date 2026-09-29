import SwiftUI
import SwiftData

@main
struct LexiNoteApp: App {
    @NSApplicationDelegateAdaptor(LexiNoteApplicationDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer

    init() {
        let container = try! ModelContainer(for: VocabWord.self, LookupCache.self)
        modelContainer = container
        Task { @MainActor in
            AppRuntime.shared.start(container: container)
            RecommendationService.shared.start(container: container)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
        } label: {
            MenuBarLabelView()
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("偏好设置…") {
                    AppRuntime.shared.open(.preferences)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
