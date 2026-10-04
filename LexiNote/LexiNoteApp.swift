import SwiftUI
import SwiftData

@main
struct LexiNoteApp: App {
    @NSApplicationDelegateAdaptor(LexiNoteApplicationDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTesting { RecommendationPreferenceMigration.initializeIfNeeded() }
        let container: ModelContainer
        if isTesting {
            container = try! ModelContainer(for: VocabWord.self, LookupCache.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } else {
            container = try! ModelContainer(for: VocabWord.self, LookupCache.self)
        }
        modelContainer = container
        if !isTesting {
            Task { @MainActor in
                AppRuntime.shared.start(container: container)
                RecommendationService.shared.start(container: container)
            }
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
