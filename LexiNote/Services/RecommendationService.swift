import AppKit
import CoreGraphics
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
    static let enabledKey = "LexiNote.recommendationsEnabled"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var statusMessage: String?

    private let center = UNUserNotificationCenter.current()
    private var modelContext: ModelContext?
    private var timer: Timer?
    private var cadence = RecommendationCadence()
    private var screenAwake = true
    private var sessionActive = true
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
                    if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                        self.startTimer()
                    } else {
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
        center.removePendingNotificationRequests(withIdentifiers: ["LexiNote.recommendation"])
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
        Task { await sendRecommendation() }
    }

    private enum Kind: String { case newWord, review }

    private func sendRecommendation() async {
        guard isEnabled, let modelContext else { return }
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
                guard await deliver(content) else { return }
                record("review:\(word.id.uuidString)", kind: kind)
                return
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
                    guard await deliver(content) else { return }
                    record("new:\(term)", kind: kind)
                    return
                }
            }
        }
    }

    private func deliver(_ content: UNMutableNotificationContent) async -> Bool {
        let request = UNNotificationRequest(identifier: "LexiNote.recommendation", content: content,
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
