import AppKit
import CoreGraphics
import SQLite3
import SwiftData
import UserNotifications

/// Counts active minutes, so sleeping or stepping away never creates a reminder backlog.
struct RecommendationCadence {
    private(set) var activeMinutes = 0
    private(set) var targetMinutes: Int

    init(targetMinutes: Int = Int.random(in: 30...120)) {
        self.targetMinutes = targetMinutes
    }

    mutating func tick(isActive: Bool, nextTarget: () -> Int = { Int.random(in: 30...120) }) -> Bool {
        guard isActive else { return false }
        activeMinutes += 1
        guard activeMinutes >= targetMinutes else { return false }
        activeMinutes = 0
        targetMinutes = nextTarget()
        return true
    }

    mutating func reset(nextTarget: () -> Int = { Int.random(in: 30...120) }) {
        activeMinutes = 0
        targetMinutes = nextTarget()
    }
}

/// The old app did not write the default-off preference until the user changed it.
/// Check for its store before SwiftData creates a new one so upgrades stay off.
enum RecommendationPreferenceMigration {
    static let enabledKey = "LexiNote.recommendationsEnabled"

    static func initializeIfNeeded(defaults: UserDefaults = .standard,
                                   hasExistingData: Bool? = nil) {
        guard defaults.object(forKey: enabledKey) == nil else { return }
        defaults.set(!(hasExistingData ?? existingInstallation(defaults: defaults)),
                     forKey: enabledKey)
    }

    private static func existingInstallation(defaults: UserDefaults) -> Bool {
        let previousKeys = ["LexiNote.globalShortcut", "LexiNote.globalSaveShortcut",
                            "LexiNote.autoRecordToLibrary", "LexiNote.recentRecommendations",
                            "LexiNote.lastRecommendationKind"]
        if previousKeys.contains(where: { defaults.object(forKey: $0) != nil }) { return true }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first else { return false }
        let path = support.appendingPathComponent("default.store").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='ZVOCABWORD' LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

enum RecommendationNotificationRoute {
    static func page(for info: [AnyHashable: Any]) -> AppPage? {
        let kind = info["kind"] as? String
        let term = info["term"] as? String
        if kind == "review", let rawID = info["id"] as? String,
           let id = UUID(uuidString: rawID) { return .word(id) }
        if kind == "newWord", let term, !term.isEmpty { return .recommendation(term) }
        return nil
    }
}

@MainActor
final class RecommendationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = RecommendationService()
    static let enabledKey = RecommendationPreferenceMigration.enabledKey

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var statusMessage: String?

    private let center = UNUserNotificationCenter.current()
    private var modelContext: ModelContext?
    private var timer: Timer?
    private var cadence = RecommendationCadence()
    private var screenAwake = true
    private var sessionActive = true
    private var isSending = false
    private var observers: [NSObjectProtocol] = []
    private var authorizationRequestID = UUID()
    private let recentKey = "LexiNote.recentRecommendations"
    private let lastKindKey = "LexiNote.lastRecommendationKind"

    private override init() { super.init() }

    func prepare() {
        center.delegate = self
    }

    func start(container: ModelContainer) {
        guard modelContext == nil else { return }
        modelContext = container.mainContext
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, awake) in [(NSWorkspace.screensDidSleepNotification, false),
                              (NSWorkspace.screensDidWakeNotification, true)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenAwake = awake }
            })
        }
        for (name, active) in [(NSWorkspace.sessionDidResignActiveNotification, false),
                               (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sessionActive = active }
            })
        }
        if isEnabled {
            center.getNotificationSettings { [weak self] settings in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isEnabled else { return }
                    switch settings.authorizationStatus {
                    case .authorized, .provisional:
                        self.startTimer()
                        AppRuntime.shared.setRecommendationShortcutEnabled(true)
                    case .notDetermined:
                        self.setEnabled(true)
                    default:
                        self.disable(message: "系统通知未获允许，请在系统设置中开启后重试。")
                    }
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else { disable(message: nil); return }
        let requestID = UUID()
        authorizationRequestID = requestID
        Task {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert])
                guard authorizationRequestID == requestID else { return }
                guard allowed else {
                    disable(message: "系统通知未获允许，请在系统设置中开启后重试。")
                    return
                }
                isEnabled = true
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                statusMessage = nil
                cadence = RecommendationCadence()
                startTimer()
                AppRuntime.shared.setRecommendationShortcutEnabled(true)
            } catch {
                guard authorizationRequestID == requestID else { return }
                disable(message: "无法开启通知：\(error.localizedDescription)")
            }
        }
    }

    private func disable(message: String?) {
        authorizationRequestID = UUID()
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        statusMessage = message
        timer?.invalidate()
        timer = nil
        AppRuntime.shared.setRecommendationShortcutEnabled(false)
        center.removeAllPendingNotificationRequests()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isEnabled else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let onConsole = session?["kCGSSessionOnConsoleKey"] as? Bool ?? true
        let active = screenAwake && sessionActive && onConsole && !locked && idle < 5 * 60
        guard cadence.tick(isActive: active) else { return }
        requestRecommendation(manual: false)
    }

    func triggerNow() {
        requestRecommendation(manual: true)
    }

    private func requestRecommendation(manual: Bool) {
        guard isEnabled, !isSending else { return }
        isSending = true
        Task {
            defer { isSending = false }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional else {
                disable(message: "系统通知未获允许，请在系统设置中开启后重试。")
                return
            }
            let delivered = await sendRecommendation()
            guard isEnabled else { return }
            if delivered {
                statusMessage = nil
                if manual { cadence.reset() }
            } else if manual && statusMessage == nil {
                statusMessage = "暂时没有符合条件的推荐词。"
            }
        }
    }

    private enum Kind: String { case newWord, review }

    private func sendRecommendation() async -> Bool {
        guard isEnabled, let modelContext else { return false }
        let saved = (try? modelContext.fetch(FetchDescriptor<VocabWord>())) ?? []
        let lastKind = Kind(rawValue: UserDefaults.standard.string(forKey: lastKindKey) ?? "")
        let preferred: Kind = lastKind == .newWord ? .review : .newWord
        let order: [Kind] = [preferred, preferred == .newWord ? .review : .newWord]
        let recent = recentRecommendations()

        for kind in order {
            switch kind {
            case .review:
                let candidates = saved.filter { $0.nextReviewAt <= .now &&
                    recent["review:\($0.id.uuidString)"].map { Date().timeIntervalSince1970 - $0 >= 24 * 3600 } ?? true
                }
                guard let word = candidates.randomElement() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "复习一下 · \(word.term)"
                content.body = "点击查看词卡，先回想它的意思。"
                content.userInfo = ["kind": kind.rawValue, "id": word.id.uuidString, "term": word.term]
                guard await deliver(content) else { return false }
                record("review:\(word.id.uuidString)", kind: kind)
                return true
            case .newWord:
                let savedTerms = Set(saved.map(\.normalizedTerm))
                let candidates = Self.candidateTerms.shuffled().filter { term in
                    !savedTerms.contains(VocabWord.normalize(term)) &&
                    (recent["new:\(term)"].map { Date().timeIntervalSince1970 - $0 >= 7 * 24 * 3600 } ?? true)
                }
                let dictionary = DictionaryService()
                for term in candidates {
                    let entry = await dictionary.localEntry(term: term)
                    guard entry.hasDefinition else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "推荐新词 · \(entry.term)"
                    content.body = entry.chineseDefinitions.first ?? entry.englishSenses.first?.englishDefinition ?? "点击查看释义"
                    content.userInfo = ["kind": kind.rawValue, "term": entry.term]
                    guard await deliver(content) else { return false }
                    record("new:\(term)", kind: kind)
                    return true
                }
            }
        }
        return false
    }

    private func deliver(_ content: UNMutableNotificationContent) async -> Bool {
        guard isEnabled else { return false }
        let request = UNNotificationRequest(identifier: "LexiNote.recommendation.\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        do {
            try await center.add(request)
            return true
        } catch {
            statusMessage = "推荐通知发送失败：\(error.localizedDescription)"
            return false
        }
    }

    private func recentRecommendations() -> [String: TimeInterval] {
        let values = UserDefaults.standard.dictionary(forKey: recentKey) as? [String: TimeInterval] ?? [:]
        let cutoff = Date().timeIntervalSince1970 - 7 * 24 * 3600
        return values.filter { $0.value >= cutoff }
    }

    private func record(_ key: String, kind: Kind) {
        var recent = recentRecommendations()
        recent[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(recent, forKey: recentKey)
        UserDefaults.standard.set(kind.rawValue, forKey: lastKindKey)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo
        let page = RecommendationNotificationRoute.page(for: info)
        Task { @MainActor in
            if let page { AppRuntime.shared.open(page) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    private static let candidateTerms = """
    adapt adequate adjacent advocate allocate ambiguous anticipate apparent approach assess assume attribute aware barrier benefit bias capacity clarify coherent collaborate complement comprehensive concise conduct consequence considerable consistent constrain context contrast contribute crucial decline derive detect devise diminish distinct diverse efficient emerge emphasize enable encounter enhance ensure establish evaluate evident feasible flexible fluctuate formulate frequent fundamental generate hypothesis illustrate implement imply incentive inevitable infer insight integrate interpret justify maintain moderate negotiate objective obtain perceive persist perspective potential precise prioritize proceed promote pursue refine reliable resolve retain reveal robust scope significant simulate specify strategy substantial sufficient sustain tendency transform transition undermine validate variable verify whereas
    """
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
        + ["account for", "carry out", "come across", "figure out", "follow up",
           "look into", "point out", "result in", "set up", "take into account"]
}

final class LexiNoteApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { RecommendationService.shared.prepare() }
    }
}
