import Foundation

public enum ActivityState: String, CaseIterable, Sendable {
    case needsInput, running, completed, failed, paused, unknown
    public var group: ActivityGroup {
        switch self { case .needsInput:return .attention; case .running:return .working; case .completed:return .ready; default:return .other }
    }
    public var label: String {
        switch self {
        case .needsInput: return "Ждёт вас"
        case .running: return "В работе"
        case .completed: return "Готово"
        case .failed: return "Ошибка"
        case .paused: return "Остановлено"
        case .unknown: return "Нет статуса"
        }
    }
    public var priority: Int {
        switch self {
        case .needsInput: return 0
        case .failed: return 1
        case .running: return 2
        case .paused: return 3
        case .unknown: return 4
        case .completed: return 5
        }
    }
}

public enum ActivityGroup: Int, CaseIterable, Sendable {
    case attention, working, ready, other
    public var title:String {
        switch self { case .attention:return "Ждёт вас"; case .working:return "В работе"; case .ready:return "Готово"; case .other:return "Другое" }
    }
}

public struct ActivityTokenUsage: Equatable, Sendable {
    public let turn: Int64?
    public let chat: Int64

    public init(turn: Int64?, chat: Int64) {
        self.turn = turn
        self.chat = chat
    }
}

public enum ActivitySource: Equatable, Sendable {
    case codex, chatGPT, work

    public var badge: String {
        switch self { case .codex: return "C"; case .chatGPT: return "G"; case .work: return "W" }
    }

    public var label: String {
        switch self { case .codex: return "Codex"; case .chatGPT: return "ChatGPT"; case .work: return "Work" }
    }
}

public struct ActivityCard: Identifiable, Equatable, Sendable {
    public var id: String { hostID + ":" + threadID }
    public let threadID: String
    public let hostID: String
    public let source: ActivitySource
    public let title: String
    public let project: String
    public let summary: String
    public let state: ActivityState
    public let updatedAt: Date
    public let turnStartedAt: Date?
    public let turnCompletedAt: Date?
    public let turnDuration: TimeInterval?
    public let pendingCount: Int
    public let waitingSince: Date?
    public let awaitingExecutionConfirmation: Bool
    public let tokenUsage: ActivityTokenUsage?
    public let turnID: String?
    public var isChatGPTHosted: Bool { hostID.hasPrefix("chatgpt:") }
    public var url: URL? {
        guard !isChatGPTHosted else { return nil }
        return ActivityPolicy.threadURL(id:threadID,host:hostID)
    }
    public init(threadID:String, hostID:String = "local", source:ActivitySource = .codex, title:String, project:String, summary:String, state:ActivityState, updatedAt:Date, turnStartedAt:Date? = nil, turnCompletedAt:Date? = nil, turnDuration:TimeInterval? = nil, pendingCount:Int = 0, waitingSince:Date? = nil, awaitingExecutionConfirmation:Bool = false, tokenUsage:ActivityTokenUsage? = nil, turnID:String? = nil) {
        self.threadID=threadID; self.hostID=hostID; self.source=source; self.title=title; self.project=project; self.summary=summary
        self.state=state; self.updatedAt=updatedAt; self.pendingCount=pendingCount
        self.turnStartedAt = turnStartedAt
        self.turnCompletedAt = turnCompletedAt
        self.turnDuration = turnDuration
        self.waitingSince = waitingSince
        self.awaitingExecutionConfirmation = awaitingExecutionConfirmation
        self.tokenUsage = tokenUsage
        self.turnID = turnID
    }
}

public struct ActivitySnapshot: Sendable {
    public var cards: [ActivityCard]
    public var observedAt: Date
    public var notice: String?
    public init(cards:[ActivityCard], observedAt:Date = Date(), notice:String? = nil) {
        self.cards=cards; self.observedAt=observedAt; self.notice=notice
    }
}

public enum ActivityPeriod: Int, CaseIterable, Sendable {
    case fourHours = 4, eightHours = 8, twelveHours = 12, day = 24, unlimited = 0

    public init(savedHours: Int?) {
        self = savedHours.flatMap(Self.init(rawValue:)) ?? .fourHours
    }
    public var label: String {
        switch self {
        case .fourHours: return "4 часа"
        case .eightHours: return "8 часов"
        case .twelveHours: return "12 часов"
        case .day: return "24 часа"
        case .unlimited: return "Без ограничения"
        }
    }
    public func cutoff(now: Date) -> Date? {
        self == .unlimited ? nil : now.addingTimeInterval(-Double(rawValue) * 3600)
    }
}

public enum ActivityPolicy {
    public static func sorted(_ cards:[ActivityCard],now:Date) -> [ActivityCard] {
        cards.sorted { a,b in
            if a.state.group != b.state.group { return a.state.group.rawValue < b.state.group.rawValue }
            let aTime = a.state == .running ? a.turnStartedAt ?? .distantPast : a.updatedAt
            let bTime = b.state == .running ? b.turnStartedAt ?? .distantPast : b.updatedAt
            return aTime == bTime ? a.id < b.id : aTime > bTime
        }
    }
    public static func age(_ date:Date,now:Date = Date(),underMinute:String = "сейчас") -> String {
        guard date.timeIntervalSince1970 > 0 else { return "нет даты" }
        let seconds=max(0,now.timeIntervalSince(date))
        if seconds < 60 { return underMinute }
        if seconds < 3600 { return "\(Int(seconds/60)) мин" }
        if seconds < 86400 { return "\(Int(seconds/3600)) ч" }
        return "\(Int(seconds/86400)) д"
    }
    public static func includes(updatedAt:Date,pending:Bool,now:Date,period:ActivityPeriod = .fourHours) -> Bool {
        pending || (period.cutoff(now:now).map { updatedAt >= $0 } ?? true)
    }
    public static func isRoot(source:String,agentPath:String?) -> Bool {
        if source.contains("subagent") { return false }
        if let path=agentPath, !path.isEmpty, path != "/root" { return false }
        return true
    }
    public static func threadURL(id:String,host:String) -> URL? {
        guard UUID(uuidString:id) != nil else { return nil }
        var parts=URLComponents(); parts.scheme="codex"; parts.host="threads"; parts.path="/"+id
        if !host.isEmpty && host != "local" { parts.queryItems=[URLQueryItem(name:"hostId",value:host)] }
        return parts.url
    }
    public static func status(turnStatus:String?,pending:Bool,lastItemStatus:String?,execution:ExecutionStatus? = nil) -> ActivityState {
        if turnStatus == "inProgress", execution != .active { return execution == .idle ? .paused : .unknown }
        if turnStatus == "inProgress", pending || ["awaitingApproval","waitingForApproval","awaitingUserInput","requiresApproval"].contains(lastItemStatus ?? "") { return .needsInput }
        switch turnStatus {
        case "inProgress": return .running
        case "completed": return .completed
        case "failed": return .failed
        case "interrupted": return .paused
        default: return .unknown
        }
    }
    public static func compact(_ text:String,limit:Int=160) -> String {
        let lines=text.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
        let line=lines.first(where:{ !$0.isEmpty && !$0.hasPrefix("```") }) ?? ""
        let clean=line.replacingOccurrences(of:"**",with:"").replacingOccurrences(of:"`",with:"")
        return clean.count > limit ? String(clean.prefix(limit-1))+"…" : clean
    }
}

public enum LifecycleAction: Equatable { case launchPanel, stopPanel, none }
public enum LifecyclePolicy {
    public static func action(codexRunning:Bool,panelRunning:Bool) -> LifecycleAction {
        if codexRunning && !panelRunning { return .launchPanel }
        if !codexRunning && panelRunning { return .stopPanel }
        return .none
    }
}
