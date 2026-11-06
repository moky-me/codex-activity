import Foundation

/// Confined to one background queue. Reads Codex's local projection; never writes to it.
public final class ActivityRepository {
    private let root: URL
    private let execution: ExecutionObserving
    public var runtimeRevision: UInt64 { execution.revision }
    private struct Questions { var tracker = QuestionTracker(); var approvalStatus: String? }
    private var trackedRunningIDs = Set<String>()
    private var questions: [String: Questions] = [:]
    private var lastLiveTurns: [String: RemoteActivity] = [:]
    private var lastRemoteCatalog: [[String: DBValue]] = []
    private var observedWaitingSince: [RuntimeThreadKey: Date] = [:]
    private var tokenReader: TokenUsageReader
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), execution: ExecutionObserving? = nil) {
        self.root = root
        self.execution = execution ?? RuntimeObserver(socketPath:root.appendingPathComponent("ipc/ipc.sock").path)
        tokenReader = TokenUsageReader(root: root)
    }

    public func load(now: Date = Date(), period: ActivityPeriod = .fourHours) throws -> ActivitySnapshot {
        let state = try SQLiteReader(url: root.appendingPathComponent("state_5.sqlite"))
        let history = try? SQLiteReader(url: root.appendingPathComponent("thread_history_1.sqlite"))
        let turnColumns = Self.columns(in: history, table: "thread_turns")
        let threadColumns = Self.columns(in: state, table: "threads")
        let turnProjection = ["duration_ms", "rollout_byte_offset", "rollout_end_byte_offset"]
            .map { turnColumns.contains($0) ? $0 : "NULL AS \($0)" }.joined(separator: ", ")
        let optionalThreadProjection = ["rollout_path", "tokens_used", "originator"]
            .map { threadColumns.contains($0) ? "t.\($0)" : "NULL AS \($0)" }.joined(separator: ", ")
        let hasProjectedOffset = turnColumns.contains("rollout_byte_offset") &&
            Self.columns(in: history, table: "thread_history_projection_state").contains("next_rollout_byte_offset")
        let projectedEnd = hasProjectedOffset
            ? "(SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id=t.thread_id)"
            : "NULL"
        let rows = try state.query("""
            SELECT t.id, t.title, t.name, t.cwd, t.source, t.agent_path, t.recency_at_ms, t.project_id, p.name AS project_name,
                   \(optionalThreadProjection)
            FROM threads t LEFT JOIN projects p ON p.id=t.project_id
            WHERE t.archived=0
              AND t.source NOT LIKE '%subagent%'
              AND (t.agent_path IS NULL OR t.agent_path='' OR t.agent_path='/root')
            """)
        let candidates = try? history?.query("""
            SELECT thread_id FROM thread_turns t WHERE status='inProgress'
              AND rollout_ordinal=(SELECT MAX(rollout_ordinal) FROM thread_turns WHERE thread_id=t.thread_id)
            """)
        let localIDs=Set(rows.compactMap { $0["id"]?.string })
        let runningIDs=(candidates.map { Set($0.compactMap { $0["thread_id"]?.string }) } ?? trackedRunningIDs).intersection(localIDs)
        trackedRunningIDs=runningIDs
        // Bound live subscriptions even when the panel shows all historical chats.
        let cutoff = ((period == .unlimited ? ActivityPeriod.day : period).cutoff(now:now) ?? now).timeIntervalSince1970 * 1000
        let recentIDs = rows.compactMap { row in
            (row["recency_at_ms"]?.number ?? 0) >= cutoff ? row["id"]?.string : nil
        }
        let runtime=execution.observe(threadIDs:runningIDs.union(recentIDs))
        var cards: [ActivityCard] = []
        var notice = history == nil ? "история codex недоступна. состояния временно неизвестны." : nil
        var liveIDs = Set<String>()
        var waitingIDs = Set<RuntimeThreadKey>()
        func waitingStart(_ key:RuntimeThreadKey, _ state:ActivityState, reportedAt:Date? = nil) -> Date? {
            guard state == .needsInput else { return nil }
            waitingIDs.insert(key)
            let firstObserved = observedWaitingSince[key] ?? now
            observedWaitingSince[key] = firstObserved
            return reportedAt ?? firstObserved
        }
        for row in rows {
            guard let id = row["id"]?.string, UUID(uuidString: id) != nil else { continue }
            liveIDs.insert(id)
            var activity = (row["recency_at_ms"]?.number ?? 0)/1000
            var turnStart: Double?
            var tracked = questions[id] ?? Questions()
            var turn: [String:DBValue]?
            var items: [[String:Any]] = []
            var historyAvailable = history != nil
            let live = runtime[id]
            let executionStatus = live?.status
            var liveWaiting = false
            if let history {
                do {
                    turn = try history.query("""
                        SELECT turn_id,status,started_at,completed_at,\(turnProjection),\(projectedEnd) AS projected_end
                        FROM thread_turns t WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1
                        """, [.text(id)]).first
                    if let started = turn?["started_at"]?.number, started.isFinite, started > 0 { turnStart = started }
                    var fresh = Questions()
                    // Match Codex's readUnansweredAsyncQuestions: historical async questions
                    // are actionable only while their turn is inProgress. Completion,
                    // interruption and a new turn all end that request's lifetime.
                    if turn?["status"]?.string == "inProgress", executionStatus == .active, let turnID=turn?["turn_id"]?.string {
                        liveWaiting = runtime[id]?.waits(for:turnID) == true
                        let updates = try history.query("""
                            SELECT item_type,created_at_ms,item_json FROM thread_items WHERE thread_id=? AND turn_id=?
                              AND item_type IN ('agentMessage','userMessage','steeringUserMessage')
                            ORDER BY rollout_ordinal
                            """, [.text(id), .text(turnID)])
                        if turnStart == nil,
                           let firstUserMessage = updates.first(where: { $0["item_type"]?.string == "userMessage" }),
                           let created = firstUserMessage["created_at_ms"]?.number, created > 0 {
                            turnStart = created / 1000
                        }
                        for item in updates {
                            guard let json = Self.decode(item["item_json"]?.string) else { continue }
                            let timestamp = item["created_at_ms"]?.number.flatMap {
                                $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970:$0 / 1000) : nil
                            }
                            fresh.tracker.consume(item:json, at:timestamp)
                        }
                        // Approval remains visible regardless of the selected period.
                        fresh.approvalStatus = try history.query("""
                            SELECT json_extract(item_json,'$.status') AS status FROM thread_items
                            WHERE thread_id=? AND turn_id=? AND json_valid(item_json)
                              AND json_extract(item_json,'$.status') IN ('awaitingApproval','waitingForApproval','awaitingUserInput','requiresApproval')
                            ORDER BY rollout_ordinal DESC LIMIT 1
                            """, [.text(id),.text(turnID)]).first?["status"]?.string
                    }
                    activity = max(activity, turn?["started_at"]?.number ?? 0, turn?["completed_at"]?.number ?? 0)
                    let latest=try history.query("SELECT created_at_ms,started_at_ms,completed_at_ms FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1",[.text(id)]).first
                    activity=max(activity,(latest?["created_at_ms"]?.number ?? 0)/1000,(latest?["started_at_ms"]?.number ?? 0)/1000,(latest?["completed_at_ms"]?.number ?? 0)/1000)
                    if ActivityPolicy.includes(updatedAt: Date(timeIntervalSince1970: activity), pending: liveWaiting || fresh.tracker.pendingCount > 0 || fresh.approvalStatus != nil, now: now, period: period) {
                        let recent = try history.query("SELECT item_json,created_at_ms,started_at_ms,completed_at_ms FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 16", [.text(id)])
                        items = recent.compactMap { Self.decode($0["item_json"]?.string) }
                        for item in recent {
                            activity = max(activity, (item["created_at_ms"]?.number ?? 0)/1000,
                                           (item["started_at_ms"]?.number ?? 0)/1000, (item["completed_at_ms"]?.number ?? 0)/1000)
                        }
                    }
                    // Publish only a successful projection. Recompute the bounded current
                    // turn so late inserts or in-place updates cannot be skipped by a cursor.
                    tracked=fresh; questions[id]=fresh
                } catch {
                    historyAvailable = false
                    notice = "формат истории изменился или база занята. последние состояния могут быть недоступны."
                }
            }
            let turnID = turn?["turn_id"]?.string
            let turnStatus = turn?["status"]?.string
            let current = live?.currentActivity
            let sameTurn = current.flatMap { activity in
                activity.isActive && turnStatus == "inProgress" && turnID != nil && activity.turnID == turnID ? activity : nil
            }
            if let sameTurn {
                if !historyAvailable { tracked = Questions() }
                tracked.tracker.merge(sameTurn.questions)
            }
            let pending = executionStatus == .active ? tracked.tracker.pendingCount : 0
            let itemStatus = executionStatus == .active ? tracked.approvalStatus : nil
            let needsInput = liveWaiting || pending > 0
            if let remembered = lastLiveTurns[id], historyAvailable,
               !remembered.isAheadOfIndex(turnID:turnID,turnStatus:turnStatus,startedAt:turnStart) {
                lastLiveTurns[id] = nil
            }
            let remembered = lastLiveTurns[id]
            let fresh = current.flatMap { activity -> RemoteActivity? in
                guard activity.isAheadOfIndex(turnID:turnID,turnStatus:turnStatus,startedAt:turnStart) else { return nil }
                if let remembered, let previousStart = remembered.startedAt {
                    guard let start = activity.startedAt, start >= previousStart,
                          activity.turnID != remembered.turnID || remembered.isActive || !activity.isActive else { return nil }
                }
                return activity
            }
            if let fresh, fresh.turnID != nil, fresh.startedAt != nil { lastLiveTurns[id] = fresh }
            let resolved = fresh ?? remembered
            let indexedStatus = historyAvailable || sameTurn != nil
                ? ActivityPolicy.status(turnStatus:turnStatus, pending:needsInput, lastItemStatus:itemStatus, execution:executionStatus)
                : .unknown
            let status = fresh?.state ?? remembered.map { $0.isActive ? .unknown : $0.state } ?? indexedStatus
            activity = max(activity,resolved?.recency?.timeIntervalSince1970 ?? 0)
            let waiting = resolved == nil ? needsInput || itemStatus != nil : status == .needsInput
            guard ActivityPolicy.includes(updatedAt:Date(timeIntervalSince1970:activity), pending:waiting, now:now, period:period) else { continue }
            var completedAt: Date?
            var duration: TimeInterval?
            if let resolved {
                turnStart = resolved.startedAt?.timeIntervalSince1970
                completedAt = resolved.completedAt
                duration = resolved.duration
                items = []
            } else if status == .completed {
                if let end = turn?["completed_at"]?.number, end.isFinite, end > 0 {
                    completedAt = Date(timeIntervalSince1970:end)
                    if let turnStart, turnStart <= end { duration = end - turnStart }
                }
                if let milliseconds = turn?["duration_ms"]?.number, milliseconds.isFinite, milliseconds >= 0 {
                    duration = milliseconds / 1000
                }
            }
            let name = Self.nonempty(row["name"]?.string) ?? Self.nonempty(row["title"]?.string) ?? "без названия"
            let project = Self.nonempty(row["project_name"]?.string) ?? Self.projectName(cwd: row["cwd"]?.string)
            let tokenBoundary: TokenUsageReader.Boundary?
            if let resolved {
                tokenBoundary = resolved.turnID.map { .live(id:$0, isOpen:resolved.isActive) }
            } else {
                tokenBoundary = historyAvailable ? TokenUsageReader.Turn(turn).map(TokenUsageReader.Boundary.indexed) : nil
            }
            let tokenUsage = tokenReader.usage(threadID: id, chat: row["tokens_used"]?.integer,
                path: row["rollout_path"]?.string, boundary: tokenBoundary)
            let question = resolved.map { $0.question ?? "нужен ответ или разрешение" } ?? tracked.tracker.firstTitle
            let source: ActivitySource = row["originator"]?.string == "codex_work_desktop" ? .work : .codex
            cards.append(ActivityCard(threadID:id, source:source, title:name, project:project,
                summary:Self.summary(state:status, question:question, items:items), state:status,
                updatedAt:Date(timeIntervalSince1970:activity),
                turnStartedAt:turnStart.map(Date.init(timeIntervalSince1970:)),
                turnCompletedAt:completedAt, turnDuration:duration, pendingCount:resolved == nil ? pending : (fresh?.questions.pendingCount ?? 0),
                waitingSince:waitingStart(RuntimeThreadKey(hostID:"local",threadID:id), status,
                                          reportedAt:resolved == nil ? tracked.tracker.oldestQuestionAt : nil),
                awaitingExecutionConfirmation:resolved == nil && historyAvailable && turnStatus == "inProgress"
                    && executionStatus != .active, tokenUsage:tokenUsage,
                turnID:resolved == nil ? turnID : resolved?.turnID))
        }
        tokenReader.retain(threads: Set(cards.map(\.threadID)))
        questions = questions.filter { liveIDs.contains($0.key) }
        lastLiveTurns = lastLiveTurns.filter { liveIDs.contains($0.key) }
        let catalog = Result { try SQLiteReader(url:root.appendingPathComponent("sqlite/codex.db")) }
        do {
            lastRemoteCatalog = try catalog.get().query("""
                SELECT c.host_id, c.thread_id, c.display_title, c.cwd, c.source_detail, c.source_recency_at
                FROM local_thread_catalog c JOIN local_thread_catalog_hosts h ON h.host_id = c.host_id
                WHERE h.host_kind IN ('ssh','wsl','remote-control') AND c.missing_candidate = 0
                """)
        } catch {
            let message = "не удалось прочитать каталог удалённых чатов codex."
            notice = notice.map { $0 + "\n" + message } ?? message
        }
        let remote = lastRemoteCatalog.compactMap { row -> (RuntimeThreadKey, [String: DBValue])? in
            guard let id = row["thread_id"]?.string, UUID(uuidString: id) != nil,
                  let host = row["host_id"]?.string, !host.isEmpty,
                  ActivityPolicy.isRoot(source: row["source_detail"]?.string ?? "", agentPath: nil) else { return nil }
            return (RuntimeThreadKey(hostID: host, threadID: id), row)
        }
        let remoteActivity = execution.observeRemote(threads: Set(remote.map { $0.0 }))
        for (key, row) in remote {
            let live = remoteActivity[key]
            let status = live?.state ?? .unknown
            let catalogDate = Date(timeIntervalSince1970: row["source_recency_at"]?.number ?? 0)
            let activity = max(catalogDate, live?.recency ?? .distantPast)
            guard ActivityPolicy.includes(updatedAt: activity, pending: status == .needsInput, now: now, period: period) else { continue }
            let summary = status == .unknown
                ? "удалённый чат · статус недоступен"
                : Self.summary(state: status, question: live?.question ?? "нужен ответ или разрешение", items: [])
            cards.append(ActivityCard(threadID: key.threadID, hostID: key.hostID,
                title: row["display_title"]?.string ?? "без названия",
                project: Self.projectName(cwd: row["cwd"]?.string), summary: summary, state: status,
                updatedAt: activity, turnStartedAt: live?.startedAt,
                turnCompletedAt: live?.completedAt, turnDuration: live?.duration,
                waitingSince:waitingStart(key,status), tokenUsage:live?.tokenUsage, turnID:live?.turnID))
        }
        if let hostID = ChatGPTCatalog.currentHost(in:root) {
            do {
                cards += try ChatGPTCatalog.cards(in:catalog.get(),hostID:hostID,now:now,period:period)
            } catch {
                let message = "не удалось прочитать локальный каталог chatgpt."
                notice = notice.map { $0 + "\n" + message } ?? message
            }
        }
        observedWaitingSince = observedWaitingSince.filter { waitingIDs.contains($0.key) }
        cards = ActivityPolicy.sorted(cards,now:now)
        return ActivitySnapshot(cards:cards,observedAt:now,notice:notice)
    }
    private static func columns(in database: SQLiteReader?, table: String) -> Set<String> {
        let rows = try? database?.query("PRAGMA table_info(\(table))")
        return Set(rows?.compactMap { $0["name"]?.string } ?? [])
    }
    private static func decode(_ text:String?) -> [String:Any]? {
        guard let data = text?.data(using:.utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
    }
    private static func nonempty(_ text:String?) -> String? {
        guard let value = text?.trimmingCharacters(in:.whitespacesAndNewlines), !value.isEmpty else { return nil }; return value
    }
    private static func projectName(cwd:String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "без проекта" }
        let parts = URL(fileURLWithPath:cwd).pathComponents
        if parts.contains("Codex"), parts.contains(where: { $0.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil }) { return "без проекта" }
        return URL(fileURLWithPath:cwd).lastPathComponent
    }
    private static func summary(state:ActivityState,question:String?,items:[[String:Any]]) -> String {
        if state == .needsInput { return ActivityPolicy.compact(question ?? "нужно ваше разрешение") }
        if state == .failed { return "задача завершилась с ошибкой" }
        if state == .paused { return "работа прервана" }
        if state == .unknown { return "состояние пока недоступно" }
        // Commentary is meant for people. Never expose tool arguments or terminal output.
        if let message = items.first(where: { ($0["type"] as? String) == "agentMessage" && !($0["text"] as? String ?? "").isEmpty }),
           let text = message["text"] as? String { return ActivityPolicy.compact(text) }
        if state == .completed { return "ответ готов" }
        switch items.first?["type"] as? String {
        case "commandExecution": return "выполняет команду"
        case "fileChange": return "изменяет файлы"
        case "webSearch": return "ищет источники"
        case "mcpToolCall": return "работает с инструментом"
        case "reasoning": return "обдумывает задачу"
        default: return "работает над задачей"
        }
    }
}
