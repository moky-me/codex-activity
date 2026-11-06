import CoreFoundation
import Foundation

public struct RemoteActivity: Equatable, Sendable {
    let turnID: String?
    public let state: ActivityState
    public let startedAt: Date?
    public let completedAt: Date?
    public let duration: TimeInterval?
    public let recency: Date?
    let questions: QuestionTracker
    public var question: String? { questions.firstTitle.map { ActivityPolicy.compact($0) } }
    var isActive: Bool { state == .running || state == .needsInput }
    public private(set) var tokenUsage: ActivityTokenUsage?

    init(snapshot: [String: Any], execution: ExecutionStatus?) {
        let usage = snapshot["latestTokenUsageInfo"] as? [String: Any]
        tokenUsage = Self.chatUsage((usage?["total"] as? [String: Any])?["totalTokens"])
        let runtime = snapshot["threadRuntimeStatus"] as? [String: Any]
        let flags = runtime?["activeFlags"] as? [String] ?? []
        let history = (snapshot["turnHistory"] as? [String: Any])?["history"] as? [String: Any]
        let islands = history?["islands"] as? [[String: Any]]
        let tail = islands?.last
        let lastKey = (tail?["entries"] as? [[String: Any]])?.last?["key"] as? String
        let canonicalTurn = lastKey.flatMap { (history?["entitiesByKey"] as? [String: Any])?[$0] as? [String: Any] }
        let legacyTurn = (snapshot["turns"] as? [[String: Any]])?.last
        let turn = history == nil ? legacyTurn : canonicalTurn
        let status = turn?["status"] as? String
        let describesCurrentTurn = execution != .active || status == "inProgress"
        turnID = describesCurrentTurn ? turn?["turnId"] as? String : nil
        let start = describesCurrentTurn ? (turn?["turnStartedAtMs"] as? NSNumber)?.doubleValue : nil
        startedAt = Self.date(milliseconds: start)
        let duration = (turn?["durationMs"] as? NSNumber)?.doubleValue
        let finished = (start ?? 0) > 0 && (duration ?? -1) >= 0 ? (start ?? 0) + (duration ?? 0) : 0
        recency = Self.date(milliseconds: max((snapshot["recencyAt"] as? NSNumber)?.doubleValue ?? 0, finished, start ?? 0))

        var tracker = QuestionTracker()
        if execution == .active, status == "inProgress" {
            for item in turn?["items"] as? [[String: Any]] ?? [] {
                tracker.consume(item: item)
            }
        }
        questions = tracker
        let currentTurnID = status == "inProgress" ? turnID : nil
        let waitingRequest = (snapshot["requests"] as? [Any] ?? []).contains { request in
            BlockingRequest(request)?.applies(to:currentTurnID) == true
        }

        switch execution {
        case .active:
            state = hasWaitingFlag(flags) || waitingRequest || tracker.pendingCount > 0 ? .needsInput : .running
        case .idle:
            // A loaded historical page can end before the actual latest turn.
            let atEnd = history == nil || (tail?["newerBoundary"] as? [String: Any])?["status"] as? String == "exhausted"
            state = atEnd ? ActivityPolicy.status(turnStatus: status, pending: false, lastItemStatus: nil, execution: .idle) : .unknown
        case nil:
            state = .unknown
        }
        completedAt = state == .completed ? Self.date(milliseconds: finished) : nil
        if state == .completed, let duration, duration.isFinite, duration >= 0 {
            self.duration = duration / 1000
        } else {
            self.duration = nil
        }
    }

    func isAheadOfIndex(turnID indexedID: String?, turnStatus: String?, startedAt indexedStart: Double?) -> Bool {
        guard state != .unknown else { return false }
        if let turnID, turnID == indexedID { return turnStatus == "inProgress" && !isActive }
        if let startedAt { return startedAt.timeIntervalSince1970 >= (indexedStart ?? 0) }
        return isActive && turnStatus != "inProgress"
    }

    mutating func applyTokenUsagePatch(_ patch: [String: Any], path: [Any]) {
        let value: Any?
        switch patch["op"] as? String {
        case "add", "replace": value = patch["value"]
        case "remove": value = nil
        default: return
        }
        if path.count == 1 {
            let usage = value as? [String: Any]
            tokenUsage = Self.chatUsage((usage?["total"] as? [String: Any])?["totalTokens"])
        } else if path[1] as? String == "total" {
            if path.count == 2 {
                tokenUsage = Self.chatUsage((value as? [String: Any])?["totalTokens"])
            } else if path.count == 3, path[2] as? String == "totalTokens" {
                tokenUsage = Self.chatUsage(value)
            }
        }
    }

    private static func chatUsage(_ value: Any?) -> ActivityTokenUsage? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let total = number as? Int64, total > 0 else { return nil }
        // The stream has no cumulative counter at the turn boundary.
        return ActivityTokenUsage(turn: nil, chat: total)
    }

    private static func date(milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
