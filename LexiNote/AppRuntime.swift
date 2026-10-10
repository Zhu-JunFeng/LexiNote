import AppKit
import SwiftData
import SwiftUI

enum AppPage: Equatable {
    case lookup
    case translation
    case dialectDictionary
    case library
    case review
    case preferences
    case word(UUID)
    case recommendation(String)
}

struct LookupRequest: Identifiable {
    let id = UUID()
    let term: String
    var openComposerWhenMissing = false
}

enum ClipboardQuery {
    static func normalized(_ value: String?) -> String? {
        guard let value, !value.contains("\n"), !value.contains("\r") else { return nil }
        let term = VocabWord.clean(value)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !term.isEmpty, term.count <= 80, term.split(separator: " ").count <= 6 else { return nil }
        let pattern = #"^[A-Za-z]+(?:['’-][A-Za-z]+)*(?: [A-Za-z]+(?:['’-][A-Za-z]+)*)*$"#
        return term.range(of: pattern, options: .regularExpression) == nil ? nil : term
    }
}

extension Notification.Name {
    static let lexiFocusLookup = Notification.Name("LexiNote.focusLookup")
}

@MainActor
final class AppRuntime: ObservableObject {
    static let shared = AppRuntime()

    @Published private(set) var shortcut: HotkeyShortcut = .defaultShortcut
    @Published private(set) var saveShortcut: HotkeyShortcut = .defaultSaveShortcut
    @Published private(set) var recommendationShortcut: HotkeyShortcut = .defaultRecommendationShortcut
    @Published private(set) var hotkeyError: String?
    @Published private(set) var page: AppPage = .lookup
    @Published private(set) var lookupRequest: LookupRequest?
    @Published private(set) var saveShortcutID = UUID()
    @Published private(set) var escapeShortcutID = UUID()
    var isRecordingShortcut = false

    private let hotkeyManager = HotkeyManager()
    private var panelController: MainPanelController?
    private var localKeyMonitor: Any?
    private var pageHistory: [AppPage] = []
    private let shortcutKey = "LexiNote.globalShortcut"
    private let saveShortcutKey = "LexiNote.globalSaveShortcut"
    private let recommendationShortcutKey = "LexiNote.globalRecommendationShortcut"
    private(set) var isRecommendationShortcutActive = false
    private var modelContext: ModelContext?
    private let dictionary = DictionaryService()
    private var saveInFlight: Set<String> = []
    private var latestSaveRequest = UUID()
    private var hasPendingOpen = false

    private init() {}

    func start(container: ModelContainer) {
        guard panelController == nil else { return }
        panelController = MainPanelController(container: container)
        modelContext = container.mainContext
        if hasPendingOpen {
            panelController?.show(page: page)
            hasPendingOpen = false
        }
        if let data = UserDefaults.standard.data(forKey: shortcutKey),
           let stored = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            shortcut = stored
        }
        if let data = UserDefaults.standard.data(forKey: saveShortcutKey),
           let stored = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            saveShortcut = stored
        }
        if let data = UserDefaults.standard.data(forKey: recommendationShortcutKey),
           let stored = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) {
            recommendationShortcut = stored
        }
        hotkeyError = nil
        register(.lookup, shortcut)
        register(.save, saveShortcut)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let character = event.charactersIgnoringModifiers?.lowercased()
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated {
                self?.handleLocalCommand(character: character, modifiers: modifiers, keyCode: keyCode) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleLocalCommand(character: String?, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        if isRecordingShortcut { return false }
        if keyCode == 53, modifiers.isEmpty {
            if page == .lookup {
                escapeShortcutID = UUID()
            } else {
                backOrHide()
            }
            return true
        }
        guard modifiers == .command else { return false }
        switch character {
        case ",":
            open(.preferences)
            return true
        case "s" where page != .preferences:
            saveShortcutID = UUID()
            return true
        default:
            return false
        }
    }

    func updateShortcut(_ newShortcut: HotkeyShortcut) {
        updateShortcut(.lookup, to: newShortcut)
    }

    func updateSaveShortcut(_ newShortcut: HotkeyShortcut) {
        updateShortcut(.save, to: newShortcut)
    }

    func updateRecommendationShortcut(_ newShortcut: HotkeyShortcut) {
        updateShortcut(.recommendation, to: newShortcut)
    }

    func setRecommendationShortcutEnabled(_ enabled: Bool) {
        guard enabled != isRecommendationShortcutActive else { return }
        if enabled {
            isRecommendationShortcutActive = register(.recommendation, recommendationShortcut)
        } else {
            hotkeyManager.unregister(action: .recommendation)
            isRecommendationShortcutActive = false
        }
    }

    private func updateShortcut(_ action: HotkeyAction, to newShortcut: HotkeyShortcut) {
        let configured: [HotkeyAction: HotkeyShortcut] = [
            .lookup: shortcut, .save: saveShortcut, .recommendation: recommendationShortcut
        ]
        guard !configured.contains(where: { $0.key != action && $0.value == newShortcut }) else {
            hotkeyError = HotkeyError.duplicateShortcut.localizedDescription
            return
        }
        do {
            if action != .recommendation || isRecommendationShortcutActive {
                try hotkeyManager.register(action: action, shortcut: newShortcut,
                                           onPress: hotkeyHandler(for: action))
            }
            switch action {
            case .lookup: shortcut = newShortcut
            case .save: saveShortcut = newShortcut
            case .recommendation: recommendationShortcut = newShortcut
            }
            hotkeyError = nil
            if let data = try? JSONEncoder().encode(newShortcut) {
                let key: String
                switch action {
                case .lookup: key = shortcutKey
                case .save: key = saveShortcutKey
                case .recommendation: key = recommendationShortcutKey
                }
                UserDefaults.standard.set(data, forKey: key)
            }
        } catch {
            hotkeyError = error.localizedDescription
        }
    }

    @discardableResult
    private func register(_ action: HotkeyAction, _ value: HotkeyShortcut) -> Bool {
        do {
            try hotkeyManager.register(action: action, shortcut: value,
                                       onPress: hotkeyHandler(for: action))
            return true
        } catch {
            hotkeyError = error.localizedDescription
            return false
        }
    }

    private func hotkeyHandler(for action: HotkeyAction) -> () -> Void {
        { [weak self] in
            guard let self, !self.isRecordingShortcut else { return }
            switch action {
            case .lookup: self.showLookupFromClipboard()
            case .save: self.saveFromClipboard()
            case .recommendation: RecommendationService.shared.triggerNow()
            }
        }
    }

    func showLookupFromClipboard(pasteboard: NSPasteboard = .general) {
        let clipboard = pasteboard.pasteboardItems?.first?.string(forType: .string)
        let term = ClipboardQuery.normalized(clipboard) ?? ""
        showLookupRequest(term: term)
    }

    private func showLookupRequest(term: String, openComposerWhenMissing: Bool = false) {
        pageHistory.removeAll()
        page = .lookup
        lookupRequest = LookupRequest(term: term, openComposerWhenMissing: openComposerWhenMissing)
        panelController?.show(page: .lookup)
    }

    func saveFromClipboard(pasteboard: NSPasteboard = .general) {
        let clipboard = pasteboard.pasteboardItems?.first?.string(forType: .string)
        guard let term = ClipboardQuery.normalized(clipboard) else {
            showLookupRequest(term: "")
            return
        }
        let requestID = UUID()
        latestSaveRequest = requestID
        let key = VocabWord.normalize(term)
        if let existing = findWord(term) {
            open(.word(existing.id))
            return
        }
        guard saveInFlight.insert(key).inserted else { return }
        Task { @MainActor in
            defer { saveInFlight.remove(key) }
            let preferred = await dictionary.preferredTerm(for: term)
            if let existing = findWord(preferred) {
                if latestSaveRequest == requestID { open(.word(existing.id)) }
                return
            }
            let local = await dictionary.localEntry(term: preferred)
            let entry = local.hasDefinition ? local : await dictionary.lookupResolved(original: term, preferred: preferred)
            if let existing = findWord(term) ?? findWord(preferred) ?? findWord(entry.term) {
                if latestSaveRequest == requestID { open(.word(existing.id)) }
                return
            }
            guard entry.hasDefinition else {
                if latestSaveRequest == requestID { showLookupRequest(term: term, openComposerWhenMissing: true) }
                return
            }
            guard let modelContext else { return }
            let word = VocabWord(term: entry.term,
                                 chineseMeaning: entry.chineseDefinitions.first ?? "",
                                 englishMeaning: entry.englishSenses.first?.englishDefinition ?? "",
                                 phonetic: entry.phonetic ?? "")
            modelContext.insert(word)
            do {
                try modelContext.save()
                if latestSaveRequest == requestID { open(.word(word.id)) }
            } catch {
                modelContext.delete(word)
                hotkeyError = "加入单词本失败：\(error.localizedDescription)"
            }
        }
    }

    private func findWord(_ term: String) -> VocabWord? {
        guard let modelContext else { return nil }
        let key = VocabWord.normalize(term)
        let descriptor = FetchDescriptor<VocabWord>(predicate: #Predicate { $0.normalizedTerm == key })
        return try? modelContext.fetch(descriptor).first
    }

    func showLookup() {
        pageHistory.removeAll()
        page = .lookup
        panelController?.show(page: .lookup)
    }

    func open(_ destination: AppPage) {
        pageHistory = destination == .lookup ? [] : [.lookup]
        page = destination
        if let panelController { panelController.show(page: destination) }
        else { hasPendingOpen = true }
    }

    func push(_ destination: AppPage) {
        guard destination != page else { return }
        pageHistory.append(page)
        page = destination
        panelController?.show(page: destination)
    }

    func backOrHide() {
        guard page != .lookup else {
            panelController?.hide()
            return
        }
        page = pageHistory.popLast() ?? .lookup
        panelController?.show(page: page)
    }

    func hide() {
        panelController?.hide()
    }
}

@MainActor
private final class MainPanelController {
    private let panel: NSPanel
    private var wasPositioned = false

    init(container: ModelContainer) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "LexiNote"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 760, height: 520)
        panel.contentView = NSHostingView(rootView: AppShellView().modelContainer(container))
    }

    func show(page: AppPage) {
        positionIfNeeded()
        panel.isFloatingPanel = page == .lookup
        panel.level = page == .lookup ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if page == .lookup {
            NotificationCenter.default.post(name: .lexiFocusLookup, object: nil)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionIfNeeded() {
        guard !wasPositioned else { return }
        wasPositioned = true
        let size = panel.frame.size
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let target = NSRect(
            x: max(visible.minX, min(visible.midX - size.width / 2, visible.maxX - size.width)),
            y: max(visible.minY, min(visible.midY - size.height / 2, visible.maxY - size.height)),
            width: size.width,
            height: size.height
        )
        panel.setFrame(target, display: true, animate: panel.isVisible)
    }
}
