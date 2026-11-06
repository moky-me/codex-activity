import AppKit
import SwiftUI
import ActivityCore
import ServiceManagement

enum AppIdentity {
    static let panel = "io.github.moky-me.CodexActivity"
    static let launcher = "io.github.moky-me.CodexActivity.Launcher"
    static let codex = "com.openai.codex"
}

protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}
struct NativeLoginService: LoginService {
    private let service = SMAppService.loginItem(identifier:AppIdentity.launcher)
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

final class PanelModel: ObservableObject {
    static let defaultRunningVerb = "Делает"
    private static let captionsKey = "runningCaptions"
    private let loginService: LoginService
    private let preferences: UserDefaults
    private var runningCaptions: RunningCaptions
    init(loginService: LoginService = NativeLoginService(), preferences: UserDefaults = .standard) {
        self.loginService = loginService; self.preferences = preferences
        runningCaptions = preferences.data(forKey:Self.captionsKey)
            .flatMap { try? JSONDecoder().decode(RunningCaptions.self,from:$0) } ?? RunningCaptions()
        launchEnabled = preferences.object(forKey:"autostartWanted") as? Bool ?? true
        showsTokens = preferences.object(forKey:"showsTokens") as? Bool ?? true
        showsCloudChats = preferences.object(forKey:"showsCloudChats") as? Bool ?? true
    }
    @Published var cards: [ActivityCard] = [] {
        didSet {
            if runningCaptions.assign(in:cards,previous:oldValue),
               let data = try? JSONEncoder().encode(runningCaptions) {
                preferences.set(data,forKey:Self.captionsKey)
            }
        }
    }
    @Published private(set) var showsTokens: Bool
    @Published private(set) var showsCloudChats: Bool
    @Published var loading = true
    @Published var notice: String?
    @Published var launchNotice: String?
    @Published private var openNotice: String?
    @Published var launchEnabled = true
    @Published private(set) var launchChanging = false
    @Published private(set) var launchNeedsApproval = false
    @Published var opening: String?
    @Published private(set) var period = ActivityPeriod(savedHours:UserDefaults.standard.object(forKey:"trackingHours") as? Int)
    let widthMM = 30.0
    private let repository = ActivityRepository()
    private let queue = DispatchQueue(label:"io.github.moky-me.CodexActivity.reader",qos:.utility)
    private var busy = false
    private var timer: Timer?
    private var fingerprint = ""
    private var lastRead = Date.distantPast

    var displayedCards: [ActivityCard] {
        showsCloudChats ? cards : cards.filter { !$0.isChatGPTHosted }
    }

    var noticeDetails: String? {
        let details = [notice, launchNotice, openNotice].compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator:"\n\n")
    }

    func runningVerb(for card: ActivityCard) -> String {
        runningCaptions.verb(for:card) ?? Self.defaultRunningVerb
    }

    func start() {
        UserDefaults.standard.removeObject(forKey:"widthMM")
        refresh(force:true)
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1
    }
    func refresh(force:Bool = false) {
        guard !busy else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let files = ["state_5.sqlite","state_5.sqlite-wal","thread_history_1.sqlite","thread_history_1.sqlite-wal","sqlite/codex.db","sqlite/codex.db-wal",".codex-global-state.json"]
        let runtimeRevision = repository.runtimeRevision
        let stamp = files.map { file -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(file).path)
            let modified=(attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(modified):\(attributes?[.size] ?? "")"
        }.joined(separator:"|") + "|runtime:\(runtimeRevision)"
        guard force || stamp != fingerprint || Date().timeIntervalSince(lastRead) > 60 else { return }
        busy = true
        let requestedPeriod = period
        let previouslyCompleted = Set(cards.lazy.filter { $0.state == .completed }.map(\.id))
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result {
                let snapshot = try self.repository.load(period:requestedPeriod)
                guard snapshot.cards.contains(where: {
                    $0.awaitingExecutionConfirmation && previouslyCompleted.contains($0.id)
                }) else { return snapshot }
                // Give the new IPC subscription time to deliver its first status before moving the card.
                Thread.sleep(forTimeInterval:0.7)
                return (try? self.repository.load(period:requestedPeriod)) ?? snapshot
            }
            DispatchQueue.main.async {
                self.busy = false
                guard self.period == requestedPeriod else {
                    self.refresh(force:true); return
                }
                self.loading = false
                switch result {
                case .success(let snapshot):
                    self.fingerprint = stamp; self.lastRead = snapshot.observedAt
                    self.cards = snapshot.cards; self.notice = snapshot.notice
                case .failure:
                    self.cards.removeAll(where:\.isChatGPTHosted)
                    self.notice = self.cards.isEmpty ? "не удалось прочитать данные codex." : "не удалось прочитать данные codex. показаны последние известные состояния."
                }
            }
        }
    }
    func open(_ card:ActivityCard) {
        guard opening == nil, !card.isChatGPTHosted else { return }
        openNotice = nil
        guard let url = card.url else {
            openNotice = "ссылка на чат недоступна"; return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier:AppIdentity.codex) else {
            openNotice = "приложение codex не найдено"; return
        }
        opening = card.id
        let config = NSWorkspace.OpenConfiguration(); config.activates = true; config.createsNewApplicationInstance = false
        NSWorkspace.shared.open([url],withApplicationAt:appURL,configuration:config) { [weak self] _,error in
            DispatchQueue.main.async {
                self?.opening = nil
                if error != nil { self?.openNotice = "codex не смог открыть этот чат" }
            }
        }
    }
    func setPeriod(_ value:ActivityPeriod) {
        guard period != value else { return }
        period = value
        UserDefaults.standard.set(value.rawValue,forKey:"trackingHours")
        refresh(force:true)
    }

    func setShowsTokens(_ value: Bool) {
        showsTokens = value
        preferences.set(value, forKey:"showsTokens")
    }

    func setShowsCloudChats(_ value: Bool) {
        showsCloudChats = value
        preferences.set(value, forKey:"showsCloudChats")
    }

    @MainActor func configureLoginItem(enable:Bool) async {
        guard !launchChanging else { return }
        launchChanging = true
        defer { launchChanging = false }
        do {
            if enable && loginService.status != .enabled && loginService.status != .requiresApproval { try loginService.register() }
            if !enable && loginService.status != .notRegistered { try await loginService.unregister() }
            preferences.set(enable,forKey:"autostartWanted")
            updateLoginStatus()
        } catch {
            updateLoginStatus()
            launchNotice = "не удалось изменить автозапуск: \(error.localizedDescription)"
        }
    }
    func updateLoginStatus() {
        let status = loginService.status
        launchEnabled = preferences.object(forKey:"autostartWanted") as? Bool ?? true
        launchNeedsApproval = launchEnabled && status == .requiresApproval
        switch status {
        case .requiresApproval where launchEnabled: launchNotice = "разрешите фоновую работу codex activity в настройках macos"
        case .notFound where launchEnabled: launchNotice = "помощник автозапуска не найден"
        default: launchNotice = nil
        }
    }
}

private struct RunningCaptions: Codable {
    private static let verbs = [
        "Ковыряется", "Химичит", "Изобретает", "Колдует", "Изготавливает",
        "Суетится", "Кочевряжится", "Симулирует", "Усердствует", "Креативит",
        "Осуществляет", "Стряпает", "Свершает", "Копошится", "Пыхтюкает",
        "Потеет", "Зиждет", "Изощряется", "Буксует", "Пытается",
        "Имитирует", "Пилит", "Вершит", "Куражится", "Соображает",
        "Ерзает", "Чудит", "Надрывается", "Барахтается", "Трудится",
        "Ладит", "Шаманит", "Ваяет", "Утомляется", "Корпит",
        "Производит", "Пробует", "Халтурит", "Изгаляется", "Тужится",
        "Филонит", "Мается", "Крутится", "Старается", "Ухищряется",
        "Выдумывает", "Содевает", "Мудрит", "Созидает", "Воплощает",
        "Возится", "Кудесничает", "Пыхтит", "Превозмогает", "Напрягается",
        "Творит", "Создаёт", "Сооружает", "Кряхтит", "Шуршит",
        "Балагурит", "Исполняет", "Мастерит", "Пашет", "Претворяет",
        "Импровизирует", "Хлопочет", "Кипит"
    ]

    private struct Assignment: Codable, Equatable {
        let turnID: String?
        let startSecond: Double?
        let verb: String

        func matches(_ card: ActivityCard) -> Bool {
            if let turnID, let current = card.turnID { return turnID == current }
            guard let startSecond else { return false }
            return startSecond == card.turnStartedAt?.timeIntervalSince1970.rounded(.down)
        }
    }

    private var entries: [ActivityCard.ID: Assignment] = [:]
    // The new order has its own cursor. Existing assignments can still be reused.
    private var nextCaptionIndexV2: Int?

    func verb(for card: ActivityCard) -> String? {
        guard let entry = entries[card.id], entry.matches(card) else { return nil }
        let verb = Self.currentSpelling(entry.verb)
        return Self.verbs.contains(verb) || verb == PanelModel.defaultRunningVerb ? verb : nil
    }

    mutating func assign(in cards: [ActivityCard], previous: [ActivityCard]) -> Bool {
        func isActive(_ card: ActivityCard) -> Bool {
            card.state == .running || card.state == .needsInput
        }
        let active = cards.filter(isActive)
        let continuing = Set(previous.lazy.filter(isActive).map(\.id))
        let reservationOrder = active.filter { continuing.contains($0.id) } +
            active.filter { !continuing.contains($0.id) }
        var used = Set<String>()
        var assigned = Set<ActivityCard.ID>()
        var changed = false

        // Reserve existing captions first, including turns waiting for a reply.
        for card in reservationOrder {
            guard let verb = verb(for:card),
                  verb == PanelModel.defaultRunningVerb || used.insert(verb).inserted else { continue }
            assigned.insert(card.id)
            changed = save(verb, for:card) || changed
        }
        for card in active where card.state == .running && !assigned.contains(card.id) {
            guard card.turnID != nil || card.turnStartedAt != nil else { continue }
            let previous = entries[card.id].map { Self.currentSpelling($0.verb) }
            let verb = nextVerb(excluding:used,previous:previous)
            used.insert(verb)
            changed = save(verb, for:card) || changed
        }
        return changed
    }

    private static func currentSpelling(_ verb: String) -> String {
        verb == "Создает" ? "Создаёт" : verb
    }

    private mutating func nextVerb(excluding used: Set<String>, previous: String?) -> String {
        let start = nextCaptionIndexV2.flatMap { Self.verbs.indices.contains($0) ? $0 : nil } ?? 0
        let free = Self.verbs.indices.map { (start + $0) % Self.verbs.count }
            .filter { !used.contains(Self.verbs[$0]) }
        guard let index = free.first(where: { Self.verbs[$0] != previous }) ?? free.first else {
            return PanelModel.defaultRunningVerb
        }
        nextCaptionIndexV2 = (index + 1) % Self.verbs.count
        return Self.verbs[index]
    }

    private mutating func save(_ verb: String, for card: ActivityCard) -> Bool {
        let old = entries[card.id]
        let matching = old.flatMap { $0.matches(card) ? $0 : nil }
        let entry = Assignment(turnID:card.turnID ?? matching?.turnID,
                               startSecond:card.turnStartedAt?.timeIntervalSince1970.rounded(.down) ?? matching?.startSecond,
                               verb:verb)
        guard entry != old else { return false }
        entries[card.id] = entry
        return true
    }
}
