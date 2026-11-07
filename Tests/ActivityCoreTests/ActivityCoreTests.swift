import Foundation
import ActivityCore

private var failures = 0
func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { if !value() { failures += 1; print("FAIL \(file):\(line)") } }
func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(!value(), file:file, line:line) }
func XCTAssertEqual<T: Equatable>(_ a:T,_ b:T,file: StaticString = #filePath,line: UInt = #line) { XCTAssertTrue(a == b,file:file,line:line) }
func XCTAssertNil<T>(_ value:T?,file: StaticString = #filePath,line: UInt = #line) { XCTAssertTrue(value == nil,file:file,line:line) }

final class FakeExecution: ExecutionObserving {
    var revision:UInt64 = 0
    var states:[String:ExecutionStatus] = [:]
    var projection = RuntimeProjection()
    var remote: [RuntimeThreadKey: RemoteActivity] = [:]
    func observeRemote(threads: Set<RuntimeThreadKey>) -> [RuntimeThreadKey: RemoteActivity] {
        remote.filter { threads.contains($0.key) }
    }
    func observe(threadIDs:Set<String>) -> [String:LocalExecution] {
        states.mapValues { LocalExecution(status:$0) }
            .merging(projection.localExecutions) { _, latest in latest }
            .filter { threadIDs.contains($0.key) }
    }
}

final class ActivityCoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let uuid = "01a1acfd-25ad-7642-af7d-f1f81731aca2"

    func testTokenUsageFollowsProjectedTurnBoundaries() throws {
        let awaitingFirstCount = ActivityCard(threadID:uuid,title:"Test",project:"Test",summary:"",
                                               state:.running,updatedAt:now,turnStartedAt:now)
        XCTAssertEqual(ActivityListLayout.cardHeight(for:awaitingFirstCount, showsTokens:true),
                       ActivityListLayout.cardHeight + ActivityListLayout.tokenRowHeight)
        XCTAssertEqual(ActivityListLayout.cardHeight(for:awaitingFirstCount, showsTokens:false),
                       ActivityListLayout.cardHeight)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = sessions.appendingPathComponent("rollout-\(uuid).jsonl")
        func sql(_ file: String, _ statement: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [root.appendingPathComponent(file).path, statement]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func counter(_ total: Int, _ last: Int) -> String {
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"total_tokens":\#(last)}}}}"# + "\n"
        }
        func marker(_ event: String, _ turn: String) -> String {
            #"{"type":"event_msg","payload":{"type":"\#(event)","turn_id":"\#(turn)"}}"# + "\n"
        }
        let previous = counter(100, 100) + marker("task_complete", "previous")
        let running = previous + marker("task_started", "latest") + counter(120, 20) + counter(120, 20)
        let finalMessage = String(repeating: "x", count: 9_000)
        let finish = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"latest","last_agent_message":"\#(finalMessage)"}}"# + "\n"
        let completed = running + counter(165, 45) + finish
        let later = completed + marker("task_started", "next") + counter(250, 85)
        try Data(later.utf8).write(to: log)
        let time = Int64(now.timeIntervalSince1970)
        try sql("state_5.sqlite", """
            CREATE TABLE projects(id TEXT,name TEXT);
            CREATE TABLE threads(id TEXT,title TEXT,name TEXT,cwd TEXT,source TEXT,agent_path TEXT,recency_at_ms INTEGER,project_id TEXT,archived INTEGER,rollout_path TEXT,tokens_used INTEGER);
            INSERT INTO threads VALUES('\(uuid)','Test',NULL,NULL,'vscode',NULL,\(time*1000),NULL,0,'\(log.path)',120);
            """)
        try sql("thread_history_1.sqlite", """
            CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER,rollout_byte_offset INTEGER,rollout_end_byte_offset INTEGER);
            CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_type TEXT,item_json TEXT,created_at_ms INTEGER,started_at_ms INTEGER,completed_at_ms INTEGER,rollout_ordinal INTEGER);
            CREATE TABLE thread_history_projection_state(thread_id TEXT,next_rollout_byte_offset INTEGER);
            INSERT INTO thread_turns VALUES('\(uuid)','latest','inProgress',\(time),NULL,3,\(previous.utf8.count),NULL);
            INSERT INTO thread_history_projection_state VALUES('\(uuid)',\(running.utf8.count));
            """)
        let execution = FakeExecution()
        execution.states[uuid] = .active
        let repository = ActivityRepository(root: root, execution: execution)
        let runningCard = try repository.load(now: now).cards.first
        XCTAssertEqual(runningCard?.tokenUsage?.turn, 20)
        XCTAssertEqual(runningCard?.tokenUsage?.chat, 120)
        XCTAssertEqual(runningCard?.state, .running)

        // Keep the projected offsets valid while corrupting the previous count.
        let corrupted = running.replacingOccurrences(of: #""total_tokens":100"#, with: #""total_tokens":"x""#)
        XCTAssertEqual(corrupted.utf8.count, running.utf8.count)
        try Data(corrupted.utf8).write(to: log, options: .atomic)
        let unreadableBaseline = try repository.load(now: now).cards.first
        XCTAssertNil(unreadableBaseline?.tokenUsage?.turn)
        XCTAssertEqual(unreadableBaseline?.tokenUsage?.chat, 120)

        let truncated = #"{"type":"event_msg","payload":{"type":"token_cou"# + "\n"
        let uncertainPrefix = counter(80, 80) + truncated + marker("task_complete", "previous")
        let uncertainTurn = uncertainPrefix + marker("task_started", "latest") + counter(120, 20)
        try Data(uncertainTurn.utf8).write(to: log, options: .atomic)
        try sql("thread_history_1.sqlite", """
            UPDATE thread_turns SET rollout_byte_offset=\(uncertainPrefix.utf8.count);
            UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(uncertainTurn.utf8.count);
            """)
        let ambiguousBaseline = try repository.load(now: now).cards.first
        XCTAssertNil(ambiguousBaseline?.tokenUsage?.turn)
        XCTAssertEqual(ambiguousBaseline?.tokenUsage?.chat, 120)

        // An intact prefix with no earlier turn still establishes a zero baseline.
        let prefix = #"{"type":"session_meta","payload":{}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"# + "\n"
        let firstTurn = prefix + marker("task_started", "latest") + counter(120, 120)
        try Data(firstTurn.utf8).write(to: log, options: .atomic)
        try sql("thread_history_1.sqlite", """
            UPDATE thread_turns SET rollout_byte_offset=\(prefix.utf8.count);
            UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(firstTurn.utf8.count);
            """)
        XCTAssertEqual(try repository.load(now: now).cards.first?.tokenUsage?.turn, 120)

        try Data(later.utf8).write(to: log, options: .atomic)
        try sql("thread_history_1.sqlite", """
            UPDATE thread_turns SET status='completed',completed_at=\(time),
              rollout_byte_offset=\(previous.utf8.count),rollout_end_byte_offset=\(completed.utf8.count);
            UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(later.utf8.count);
            """)
        try sql("state_5.sqlite", "UPDATE threads SET tokens_used=250;")
        let completedCard = try repository.load(now: now).cards.first
        XCTAssertEqual(completedCard?.tokenUsage?.turn, 65)
        XCTAssertEqual(completedCard?.tokenUsage?.chat, 250)
        if let completedCard {
            let other = ActivityCard(threadID:"remote",hostID:"ssh:host",title:"Other",project:"Test",
                summary:"",state:.completed,updatedAt:now)
            let mixed = ActivityListLayout(cards:[completedCard, other], now:now)
            XCTAssertEqual(mixed.cardTop(at:1) - mixed.cardTop(at:0), 150)
            XCTAssertEqual(mixed.height - mixed.cardTop(at:1), 131)
        }

        try sql("thread_history_1.sqlite", "UPDATE thread_turns SET rollout_byte_offset=1;")
        let invalidCard = try repository.load(now: now).cards.first
        XCTAssertNil(invalidCard?.tokenUsage?.turn)
        XCTAssertEqual(invalidCard?.tokenUsage?.chat, 250)

        let key = RuntimeThreadKey(hostID:"local",threadID:uuid)
        func live(_ turnID: String, revision: Int, active: Bool = true) {
            _ = execution.projection.consume([
                "type":"broadcast", "method":"thread-stream-state-changed", "version":11, "sourceClientId":"desktop",
                "params":["hostId":"local", "conversationId":uuid, "change":[
                    "type":"snapshot", "revision":revision, "conversationState":[
                        "threadRuntimeStatus":["type":active ? "active" : "idle"],
                        "turns":[["turnId":turnID, "status":active ? "inProgress" : "completed",
                                  "turnStartedAtMs":(time+1)*1000]]
                    ]
                ]]
            ],watching:[key])
        }
        live("next",revision:1)
        XCTAssertEqual(try repository.load(now:now).cards.first?.tokenUsage?.turn, 85)
        live("next",revision:2,active:false)
        XCTAssertNil(try repository.load(now:now).cards.first?.tokenUsage?.turn)
        try Data((later + marker("task_complete","next")).utf8).write(to:log,options:.atomic)
        XCTAssertEqual(try repository.load(now:now).cards.first?.tokenUsage?.turn, 85)
        live("other",revision:3)
        XCTAssertNil(try repository.load(now:now).cards.first?.tokenUsage?.turn)

        let renamedLog = sessions.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(uuid)"}}"# + "\n"
        try Data((header + later).utf8).write(to:renamedLog)
        try sql("state_5.sqlite","UPDATE threads SET rollout_path='\(renamedLog.path)';")
        live("next",revision:4)
        XCTAssertEqual(try repository.load(now:now).cards.first?.tokenUsage?.turn, 85)
        try Data((later + finish).utf8).write(to:renamedLog,options:.atomic)
        XCTAssertNil(try repository.load(now:now).cards.first?.tokenUsage?.turn)

        let longTurnStart = header + completed
        let output = #"{"type":"response_item","payload":{"output":"\#(String(repeating: "x", count: 8192))"}}"# + "\n"
        let longTurn = longTurnStart + marker("task_started", "next") +
            String(repeating: output, count: 1152) + counter(250, 85) + marker("task_complete", "next")
        try Data(longTurn.utf8).write(to:renamedLog,options:.atomic)
        live("next",revision:5,active:false)
        let longCompleted = try repository.load(now:now).cards.first
        XCTAssertEqual(longCompleted?.state, .completed)
        XCTAssertEqual(longCompleted?.tokenUsage?.turn, 85)

        try sql("thread_history_1.sqlite", """
            UPDATE thread_turns SET turn_id='next',started_at=\(time+1),
              rollout_byte_offset=\(longTurnStart.utf8.count),rollout_end_byte_offset=\(longTurn.utf8.count);
            """)
        XCTAssertEqual(try repository.load(now:now).cards.first?.tokenUsage?.turn, 85)
        let wrongHeader = longTurn.replacingOccurrences(of:uuid,with:UUID().uuidString)
        try Data(wrongHeader.utf8).write(to:renamedLog,options:.atomic)
        XCTAssertNil(try repository.load(now:now).cards.first?.tokenUsage?.turn)

        try sql("state_5.sqlite","UPDATE threads SET rollout_path='\(log.path)';")
        execution.projection.reset()

        try sql("thread_history_1.sqlite", """
            UPDATE thread_turns SET turn_id='latest',started_at=\(time),
              rollout_byte_offset=\(previous.utf8.count),rollout_end_byte_offset=\(completed.utf8.count);
            """)
        let moved = root.appendingPathComponent(log.lastPathComponent)
        try FileManager.default.moveItem(at: log, to: moved)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: moved)
        XCTAssertNil(try repository.load(now: now).cards.first?.tokenUsage?.turn)
    }

    func testFourHourBoundaryAndPendingOverride() {
        XCTAssertTrue(ActivityPolicy.includes(updatedAt: now.addingTimeInterval(-14400), pending: false, now: now))
        XCTAssertFalse(ActivityPolicy.includes(updatedAt: now.addingTimeInterval(-14401), pending: false, now: now))
        XCTAssertTrue(ActivityPolicy.includes(updatedAt: now.addingTimeInterval(-86400), pending: true, now: now))
        for (seconds, label) in [(59,"<1 мин"), (60,"1 мин"), (3599,"59 мин"), (3600,"1 ч"), (86400,"1 д")] {
            XCTAssertEqual(ActivityPolicy.age(now.addingTimeInterval(-Double(seconds)),
                                             now:now, underMinute:"<1 мин"), label)
        }
    }

    func testAllPeriodsBoundariesAndSavedPreference() {
        XCTAssertEqual(ActivityPeriod(savedHours:nil),.fourHours)
        XCTAssertEqual(ActivityPeriod(savedHours:27),.fourHours)
        for period in ActivityPeriod.allCases {
            XCTAssertEqual(ActivityPeriod(savedHours:period.rawValue),period)
            XCTAssertTrue(ActivityPolicy.includes(updatedAt:now.addingTimeInterval(-1_000_000),pending:true,now:now,period:period))
            if let cutoff=period.cutoff(now:now) {
                XCTAssertTrue(ActivityPolicy.includes(updatedAt:cutoff,pending:false,now:now,period:period))
                XCTAssertFalse(ActivityPolicy.includes(updatedAt:cutoff.addingTimeInterval(-1),pending:false,now:now,period:period))
            } else {
                XCTAssertTrue(ActivityPolicy.includes(updatedAt:Date(timeIntervalSince1970:0),pending:false,now:now,period:period))
            }
        }
    }

    func testPeriodChangesIncludeLocalAndRemoteHistory() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("sqlite"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func sql(_ name:String,_ sql:String) throws {
            let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3")
            process.arguments=[root.appendingPathComponent(name).path]
            let pipe=Pipe(); process.standardInput=pipe; try process.run()
            pipe.fileHandleForWriting.write(Data(sql.utf8)); try pipe.fileHandleForWriting.close()
            process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        }
        var localSQL="""
        CREATE TABLE projects(id TEXT,name TEXT);
        CREATE TABLE threads(id TEXT,title TEXT,name TEXT,cwd TEXT,source TEXT,agent_path TEXT,updated_at REAL,updated_at_ms REAL,recency_at_ms REAL,project_id TEXT,archived INTEGER);
        """
        var remoteSQL="""
        CREATE TABLE local_thread_catalog_hosts(host_id TEXT,host_kind TEXT);
        INSERT INTO local_thread_catalog_hosts VALUES('ssh:test','ssh');
        CREATE TABLE local_thread_catalog(host_id TEXT,thread_id TEXT,display_title TEXT,cwd TEXT,source_detail TEXT,source_updated_at REAL,source_recency_at REAL,missing_candidate INTEGER);
        """
        let oldRemoteID = UUID().uuidString
        for hours in [2,6,10,18,30] {
            let time=now.timeIntervalSince1970-Double(hours)*3600
            localSQL += "INSERT INTO threads VALUES('\(UUID().uuidString)','local-\(hours)',NULL,'/tmp/P','vscode',NULL,\(time),NULL,\(time*1000),NULL,0);"
            let remoteID = hours == 30 ? oldRemoteID : UUID().uuidString
            remoteSQL += "INSERT INTO local_thread_catalog VALUES('ssh:test','\(remoteID)','remote-\(hours)','/tmp/R','vscode',\(time),\(time),0);"
        }
        // Unlimited must still respect root-chat and archive/missing exclusions.
        localSQL += "INSERT INTO threads VALUES('\(UUID().uuidString)','archived',NULL,NULL,'vscode',NULL,0,NULL,NULL,NULL,1);"
        localSQL += "INSERT INTO threads VALUES('\(UUID().uuidString)','subagent',NULL,NULL,'vscode','/root/review',0,NULL,NULL,NULL,0);"
        remoteSQL += "INSERT INTO local_thread_catalog VALUES('ssh:test','\(UUID().uuidString)','missing',NULL,'vscode',0,0,1);"
        try sql("state_5.sqlite",localSQL)
        try sql("sqlite/codex.db",remoteSQL)
        // Settings/catalog refresh is fresh for every record; only conversational recency counts.
        try sql("state_5.sqlite","UPDATE threads SET updated_at=\(now.timeIntervalSince1970),updated_at_ms=\(now.timeIntervalSince1970*1000);")
        try sql("sqlite/codex.db","UPDATE local_thread_catalog SET source_updated_at=\(now.timeIntervalSince1970);")
        let live = FakeExecution()
        let repository=ActivityRepository(root:root,execution:live)
        // Reuse the reader and change periods both ways; cached projections must not hide older cards.
        let expected:[(ActivityPeriod,[Int])]=[(.fourHours,[2]),(.eightHours,[2,6]),(.twelveHours,[2,6,10]),(.day,[2,6,10,18]),(.unlimited,[2,6,10,18,30]),(.fourHours,[2])]
        for (period,hours) in expected {
            let cards=try repository.load(now:now,period:period).cards
            XCTAssertEqual(Set(cards.map(\.title)),Set(hours.flatMap { ["local-\($0)","remote-\($0)"] }))
        }

        // A real waiting state from the remote stream bypasses the age cutoff.
        let key = RuntimeThreadKey(hostID: "ssh:test", threadID: oldRemoteID)
        var projection = RuntimeProjection()
        _ = projection.consume([
            "type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
            "sourceClientId": "owner", "params": ["hostId": key.hostID, "conversationId": key.threadID,
                "change": ["type": "snapshot", "revision": 1, "conversationState": [
                    "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]],
                    "latestTokenUsageInfo": ["total": ["totalTokens": 120], "last": ["totalTokens": 19]]
                ]]]
        ], watching: [key])
        live.remote = projection.remoteActivities
        let waiting = try repository.load(now: now).cards.first
        XCTAssertEqual(waiting?.threadID, oldRemoteID)
        XCTAssertEqual(waiting?.state, .needsInput)
        XCTAssertEqual(waiting?.tokenUsage?.chat, 120)
        XCTAssertNil(waiting?.tokenUsage?.turn)
        XCTAssertEqual(waiting?.waitingSince, now)
        XCTAssertEqual(try repository.load(now:now.addingTimeInterval(90)).cards.first?.waitingSince, now)
        XCTAssertEqual(waiting?.url, ActivityPolicy.threadURL(id: oldRemoteID, host: "ssh:test"))
        live.remote = [:]
        let afterDisconnect = try repository.load(now: now).cards
        XCTAssertFalse(afterDisconnect.contains { $0.threadID == oldRemoteID })

        let beforeCatalogFailure = try repository.load(now:now)
        try sql("sqlite/codex.db","ALTER TABLE local_thread_catalog RENAME TO catalog_backup;")
        let catalogFailure = try repository.load(now:now)
        XCTAssertEqual(catalogFailure.cards.map(\.id), beforeCatalogFailure.cards.map(\.id))
        XCTAssertTrue(catalogFailure.notice?.contains("каталог удалённых чатов") == true)
        try sql("sqlite/codex.db","ALTER TABLE catalog_backup RENAME TO local_thread_catalog; DELETE FROM local_thread_catalog;")
        let emptyCatalog = try repository.load(now:now)
        XCTAssertEqual(emptyCatalog.cards.map(\.title), ["local-2"])
        XCTAssertEqual(emptyCatalog.notice, beforeCatalogFailure.notice)
    }

    func testChatGPTCatalogAndLocalWorkStatuses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sqlite"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func sql(_ file: String, _ statement: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath:"/usr/bin/sqlite3")
            process.arguments = [root.appendingPathComponent(file).path, statement]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let active = UUID().uuidString
        let ready = UUID().uuidString
        let history = UUID().uuidString
        let old = UUID().uuidString
        let work = UUID().uuidString
        let time = Int64(now.timeIntervalSince1970)
        let identity = root.appendingPathComponent(".codex-global-state.json")
        let identityJSON = #"{"electron-persisted-atom-state":{"local-document-identity":{"accountId":"account","userId":"user"}}}"#
        try Data(identityJSON.utf8).write(to: identity)
        try sql("state_5.sqlite", """
            CREATE TABLE projects(id TEXT,name TEXT);
            CREATE TABLE threads(id TEXT,title TEXT,name TEXT,cwd TEXT,source TEXT,agent_path TEXT,recency_at_ms REAL,project_id TEXT,archived INTEGER,originator TEXT);
            INSERT INTO threads VALUES('\(work)','Local Work',NULL,NULL,'vscode',NULL,\(time*1000),NULL,0,'codex_work_desktop');
            """)
        try sql("sqlite/codex.db", """
            CREATE TABLE local_thread_catalog_hosts(host_id TEXT,host_kind TEXT);
            INSERT INTO local_thread_catalog_hosts VALUES('chatgpt:account:user','chatgpt'),('chatgpt:other:user','chatgpt');
            CREATE TABLE local_thread_catalog(host_id TEXT,thread_id TEXT,display_title TEXT,cwd TEXT,source_detail TEXT,
                source_recency_at REAL,missing_candidate INTEGER,source_kind TEXT,project_id TEXT,conversation_origin TEXT,
                trial_conversation_type TEXT,chatgpt_async_status INTEGER);
            INSERT INTO local_thread_catalog VALUES
              ('chatgpt:account:user','\(active)','Streaming',NULL,NULL,\(time-60),0,'chatgpt',NULL,NULL,NULL,3),
              ('chatgpt:account:user','\(ready)','Ready',NULL,NULL,\(time-120),0,'chatgpt','g-p-demo',NULL,NULL,4),
              ('chatgpt:account:user','\(UUID())','Cloud Work by origin',NULL,NULL,\(time),0,'chatgpt',NULL,'tpp',NULL,4),
              ('chatgpt:account:user','\(UUID())','Cloud Work by trial type',NULL,NULL,\(time),0,'chatgpt',NULL,NULL,'work',3),
              ('chatgpt:account:user','\(history)','History',NULL,NULL,\(time-180),0,'chatgpt',NULL,NULL,NULL,NULL),
              ('chatgpt:account:user','\(old)','Old streaming',NULL,NULL,\(time-90_000),0,'chatgpt',NULL,NULL,NULL,3),
              ('chatgpt:account:user','\(UUID())','Missing',NULL,NULL,\(time),1,'chatgpt',NULL,NULL,NULL,NULL),
              ('chatgpt:other:user','\(UUID())','Other account',NULL,NULL,\(time),0,'chatgpt',NULL,NULL,NULL,3);
            """)
        try sql("thread_history_1.sqlite", """
            CREATE TABLE thread_turns(thread_id TEXT,rollout_ordinal INTEGER,status TEXT,started_at REAL,completed_at REAL,turn_id TEXT,duration_ms REAL);
            CREATE TABLE thread_items(thread_id TEXT,rollout_ordinal INTEGER,item_type TEXT,item_json TEXT,created_at_ms REAL,started_at_ms REAL,completed_at_ms REAL,turn_id TEXT);
            INSERT INTO thread_turns VALUES('\(work)',1,'inProgress',\(time-180),NULL,'work-turn',NULL);
            """)
        let live = FakeExecution()
        let workKey = RuntimeThreadKey(hostID:"local",threadID:work)
        func observeWork(_ revision:Int, status:String, flags:[String] = []) {
            let active = status == "inProgress"
            let turn: [String:Any] = ["turnId":"work-turn","status":status,
                                     "turnStartedAtMs":(time-180)*1000,"durationMs":180_000]
            _ = live.projection.consume([
                "type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":"owner",
                "params":["hostId":"local","conversationId":work,"change":[
                    "type":"snapshot","revision":revision,"conversationState":[
                        "threadRuntimeStatus":["type":active ? "active" : "idle","activeFlags":flags],
                        "turns":[turn]
                    ]
                ]]
            ], watching:[workKey])
        }
        let repository = ActivityRepository(root:root,execution:live)
        observeWork(1,status:"inProgress")
        let cards = try repository.load(now:now).cards
        XCTAssertEqual(Set(cards.map(\.title)), ["Streaming","Ready","History","Local Work",
                                                  "Cloud Work by origin","Cloud Work by trial type"])
        let streaming = cards.first { $0.threadID == active }
        XCTAssertEqual(streaming?.state, .running)
        XCTAssertEqual(streaming?.source, .chatGPT)
        if let streaming {
            XCTAssertEqual(ActivityListLayout.cardHeight(for:streaming,showsTokens:true), ActivityListLayout.cardHeight)
        }
        XCTAssertNil(streaming?.turnStartedAt)
        XCTAssertNil(streaming?.url)
        let readyChat = cards.first { $0.threadID == ready }
        XCTAssertEqual(readyChat?.state, .completed)
        XCTAssertEqual(readyChat?.source, .chatGPT)
        XCTAssertEqual(readyChat?.project, "проект")
        XCTAssertNil(readyChat?.turnCompletedAt)
        XCTAssertNil(readyChat?.url)
        let hostedWork = cards.filter { $0.source == .work && $0.isChatGPTHosted }
        XCTAssertEqual(hostedWork.count, 2)
        XCTAssertEqual(Set(hostedWork.map(\.state)), [.running, .completed])
        XCTAssertTrue(hostedWork.allSatisfy { $0.url == nil && $0.turnStartedAt == nil && $0.turnCompletedAt == nil })
        let localWork = cards.first { $0.threadID == work }
        XCTAssertEqual(localWork?.source, .work)
        XCTAssertEqual(localWork?.url, ActivityPolicy.threadURL(id:work,host:"local"))
        XCTAssertEqual(localWork?.state, .running)
        XCTAssertEqual(localWork?.turnStartedAt,now.addingTimeInterval(-180))
        observeWork(2,status:"inProgress",flags:["waitingOnApproval"])
        XCTAssertEqual(try repository.load(now:now).cards.first { $0.threadID == work }?.state, .needsInput)
        observeWork(3,status:"completed")
        let completedWork = try repository.load(now:now).cards.first { $0.threadID == work }
        XCTAssertEqual(completedWork?.state, .completed)
        XCTAssertEqual(completedWork?.turnCompletedAt,now)
        XCTAssertEqual(completedWork?.turnDuration,180)
        live.projection.reset()
        XCTAssertEqual(try repository.load(now:now).cards.first { $0.threadID == work }?.state, .completed)
        XCTAssertEqual(cards.first { $0.threadID == history }?.state, .unknown)
        let unlimited = try repository.load(now:now,period:.unlimited).cards
        XCTAssertEqual(unlimited.first { $0.threadID == old }?.state, .unknown)
        try Data(identityJSON.replacingOccurrences(of:#""accountId":"account""#,with:#""accountId":"other""#).utf8)
            .write(to:identity,options:.atomic)
        XCTAssertEqual(Set(try repository.load(now:now).cards.map(\.title)), ["Other account","Local Work"])
        try Data("{}".utf8).write(to: identity, options:.atomic)
        XCTAssertEqual(try repository.load(now:now,period:.unlimited).cards.map(\.title), ["Local Work"])
    }

    func testRuntimeProjectionAndUnconfirmedTurns() {
        XCTAssertEqual(ActivityPolicy.status(turnStatus:"inProgress",pending:false,lastItemStatus:nil),.unknown)
        XCTAssertEqual(ActivityPolicy.status(turnStatus:"inProgress",pending:true,lastItemStatus:nil,execution:.idle),.paused)
        XCTAssertEqual(ActivityPolicy.status(turnStatus:"inProgress",pending:false,lastItemStatus:nil,execution:.active),.running)
        var projection=RuntimeProjection()
        let key = RuntimeThreadKey(hostID: "local", threadID: uuid)
        func message(_ change:[String:Any],version:Int=11) -> [String:Any] {
            ["type":"broadcast","method":"thread-stream-state-changed","version":version,"sourceClientId":"owner","params":["hostId":"local","conversationId":uuid,"change":change]]
        }
        let snapshot:[String:Any] = ["type":"snapshot","revision":1,"conversationState":["threadRuntimeStatus":["type":"active"]]]
        _=projection.consume(message(snapshot),watching:[key])
        XCTAssertEqual(projection.statuses[key],.active)
        _=projection.consume(message(["type":"patches","baseRevision":1,"revision":2,"patches":[["op":"replace","path":["threadRuntimeStatus"],"value":["type":"idle"]]]]),watching:[key])
        XCTAssertEqual(projection.statuses[key],.idle)
        let gap=projection.consume(message(["type":"patches","baseRevision":3,"revision":4,"patches":[]]),watching:[key])
        XCTAssertEqual(gap,key); XCTAssertNil(projection.statuses[key])
        _=projection.consume(message(snapshot,version:99),watching:[key])
        XCTAssertNil(projection.statuses[key])
        _=projection.consume(message(snapshot),watching:[key])
        _=projection.consume(["type":"broadcast","method":"client-status-changed","params":["clientId":"owner","status":"disconnected"]],watching:[key])
        XCTAssertNil(projection.statuses[key])
        _=projection.consume(message(snapshot),watching:[key]); projection.reset()
        XCTAssertNil(projection.statuses[key])
    }

    func testRemoteActivityProjection() {
        let host = "remote-control:test"
        let remote = RuntimeThreadKey(hostID: host, threadID: uuid)
        let local = RuntimeThreadKey(hostID: "local", threadID: uuid)
        let watching: Set<RuntimeThreadKey> = [remote, local]
        let start = now.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        var projection = RuntimeProjection()

        func message(_ host: String, _ change: [String: Any]) -> [String: Any] {
            ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
             "sourceClientId": host, "params": ["hostId": host, "conversationId": uuid, "change": change]]
        }
        func snapshot(_ version: Int, runtime: String, flags: [String] = [],
                      status: String = "inProgress", boundary: String = "exhausted",
                      requests: [[String: Any]] = [], items: [[String: Any]] = []) -> [String: Any] {
            let turn: [String: Any] = ["turnId": "turn", "status": status,
                                       "turnStartedAtMs": start, "durationMs": 30000, "items": items]
            let island: [String: Any] = ["entries": [["key": "turn:1"]],
                                         "newerBoundary": ["status": boundary]]
            return message(host, ["type": "snapshot", "revision": version, "conversationState": [
                "threadRuntimeStatus": ["type": runtime, "activeFlags": flags],
                "requests": requests,
                "latestTokenUsageInfo": ["total": ["totalTokens": 120], "last": ["totalTokens": 19]],
                "turnHistory": ["kind": "canonical", "history": ["islands": [island], "entitiesByKey": ["turn:1": turn]]]
            ]])
        }
        _ = projection.consume(message("local", ["type": "snapshot", "revision": 1,
                              "conversationState": ["threadRuntimeStatus": ["type": "idle"]]]), watching: watching)
        _ = projection.consume(snapshot(1, runtime: "active"), watching: watching)
        XCTAssertEqual(projection.statuses[local], .idle)
        XCTAssertEqual(projection.remoteActivities[remote]?.state, .running)
        XCTAssertEqual(projection.remoteActivities[remote]?.startedAt, now.addingTimeInterval(-60))
        XCTAssertNil(projection.remoteActivities[remote]?.completedAt)
        let usageUpdate = message(host, ["type": "patches", "baseRevision": 1, "revision": 2,
            "patches": [
                ["path": ["turnHistory", "history", "entitiesByKey", "turn:1", "items", 1, "text"]],
                ["op": "replace", "path": ["latestTokenUsageInfo", "total", "totalTokens"], "value": 240],
                ["op": "replace", "path": ["latestTokenUsageInfo", "last", "totalTokens"], "value": 42]
            ]])
        XCTAssertNil(projection.consume(usageUpdate, watching: watching))
        XCTAssertEqual(projection.remoteActivities[remote]?.tokenUsage?.chat, 240)
        XCTAssertNil(projection.remoteActivities[remote]?.tokenUsage?.turn)
        let waiting = message(host, ["type": "patches", "baseRevision": 2, "revision": 3,
            "patches": [["path": ["threadRuntimeStatus", "activeFlags"]]]])
        XCTAssertEqual(projection.consume(waiting, watching: watching), remote)
        _ = projection.consume(snapshot(3, runtime: "active", flags: ["waitingOnUserInput"]), watching: watching)
        XCTAssertEqual(projection.remoteActivities[remote]?.state, .needsInput)
        let request = ["method": "item/commandExecution/requestApproval", "params": ["turnId": "turn"]] as [String: Any]
        _ = projection.consume(snapshot(4, runtime: "active", requests: [request]), watching: watching)
        XCTAssertEqual(projection.remoteActivities[remote]?.state, .needsInput)
        _ = projection.consume(snapshot(5, runtime: "idle", status: "completed", boundary: "available"), watching: watching)
        XCTAssertEqual(projection.remoteActivities[remote]?.state, .unknown)
        _ = projection.consume(snapshot(6, runtime: "idle", status: "completed", requests: [request]), watching: watching)
        XCTAssertEqual(projection.remoteActivities[remote]?.state, .completed)
        XCTAssertEqual(projection.remoteActivities[remote]?.recency, now.addingTimeInterval(-30))
        XCTAssertEqual(projection.remoteActivities[remote]?.completedAt, now.addingTimeInterval(-30))
        XCTAssertEqual(projection.remoteActivities[remote]?.duration, 30)
        let usageRemoval = message(host, ["type": "patches", "baseRevision": 6, "revision": 7,
            "patches": [["op": "remove", "path": ["latestTokenUsageInfo"]]]])
        XCTAssertNil(projection.consume(usageRemoval, watching: watching))
        XCTAssertNil(projection.remoteActivities[remote]?.tokenUsage)
        let question: [String: Any] = ["type":"agentMessage", "id":"q", "questions":[["title":"Продолжить?"]]]
        let followUp: [String: Any] = ["type":"userMessage", "content":[["type":"text", "text":"Продолжай"]]]
        let commentary = ["type":"agentMessage", "phase":"commentary", "text":"Продолжаю"]
        let commentaryPatch: [[String: Any]] = [["op":"add",
            "path":["turnHistory","history","entitiesByKey","turn:1","items",2], "value":commentary]]
        _ = projection.consume(snapshot(8,runtime:"active",items:[question]),watching:watching)
        XCTAssertNil(projection.consume(message(host,["type":"patches","baseRevision":8,"revision":9,
            "patches":commentaryPatch]),watching:watching))
        _ = projection.consume(snapshot(10,runtime:"active",items:[question,followUp]),watching:watching)
        XCTAssertEqual(projection.remoteActivities[remote]?.state,.needsInput)
        XCTAssertEqual(projection.consume(message(host,["type":"patches","baseRevision":10,"revision":11,
            "patches":commentaryPatch]),watching:watching),remote)
        _ = projection.consume(snapshot(11,runtime:"active",items:[question,followUp,commentary]),watching:watching)
        XCTAssertEqual(projection.remoteActivities[remote]?.state,.running)
        _ = projection.consume(["type": "broadcast", "method": "client-status-changed",
                                "params": ["status": "disconnected", "clientId": host]], watching: watching)
        XCTAssertNil(projection.remoteActivities[remote])
        XCTAssertEqual(projection.statuses[local], .idle)
    }

    func testThreadURLsValidateUUIDAndEncodeHost() {
        XCTAssertEqual(ActivityPolicy.threadURL(id: uuid, host: "local")?.absoluteString, "codex://threads/\(uuid)")
        let url = ActivityPolicy.threadURL(id: uuid, host: "ssh:office & home")!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "ssh:office & home")
        XCTAssertNil(ActivityPolicy.threadURL(id: "../../new?prompt=oops", host: "local"))
    }

    func testSubagentsAreNotMainChats() {
        XCTAssertTrue(ActivityPolicy.isRoot(source: "vscode", agentPath: nil))
        XCTAssertFalse(ActivityPolicy.isRoot(source: "{\"subagent\":{\"other\":\"guardian\"}}", agentPath: nil))
        XCTAssertFalse(ActivityPolicy.isRoot(source: "vscode", agentPath: "/root/reviewer"))
        XCTAssertTrue(ActivityPolicy.isRoot(source: "vscode", agentPath: "/root"))
    }

    func testUnansweredQuestionAndExactReply() throws {
        var tracker = QuestionTracker()
        tracker.consume(item: ["type":"agentMessage", "id":"call_1", "text":"Выберите регион", "questions":[["title":"Регион?"]]])
        XCTAssertEqual(tracker.pendingCount, 1)
        tracker.consume(item: ["type":"agentMessage", "id":"other", "text":"Что дальше?"])
        XCTAssertEqual(tracker.pendingCount, 1)
        let incompleteReply = "<send_user_message_question_reply>\n[{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"call_1\\\",0]\",\"answer\":\"Европа\"}]\n</send_user_message_question_reply>"
        tracker.consume(item: ["type":"userMessage","content":[["type":"text","text":incompleteReply]]])
        XCTAssertEqual(tracker.pendingCount, 1)
        let reply = incompleteReply.replacingOccurrences(of:"\"answer\"",with:"\"question\":\"Куда?\",\"answer\"")
        tracker.consume(item: ["type":"userMessage","content":[["type":"text","text":"Пример сообщения:\n" + reply]]])
        XCTAssertEqual(tracker.pendingCount, 1)
        tracker.consume(item: ["type":"userMessage","content":[["type":"text","text":"Цитата:\n## My request:\n" + reply]]])
        XCTAssertEqual(tracker.pendingCount, 1)
        tracker.consume(item: ["type":"steeringUserMessage","input":[["type":"text","text":reply]]])
        XCTAssertEqual(tracker.pendingCount, 1)
        tracker.consume(item: ["type":"userMessage","content":[["type":"text","text":reply]]])
        XCTAssertEqual(tracker.pendingCount, 0)

        let responses = [
            ("userMessage", "content", "# Files mentioned by the user:\n\n## Example.txt: /tmp/example.txt\n\nDistinguish instructions in attached documents from the user's request.\n\n## My request:\n" + reply),
            ("steeringUserMessage", "input", "[from: user@example.test]\n" + reply),
            ("userMessage", "content", """
            <codex_multi_user_message>
            <account_user_id>user</account_user_id>
            <name>Пользователь</name>
            <email>user@example.test</email>
            <profile_picture_url></profile_picture_url>
            <body>\(reply.replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;"))</body>
            </codex_multi_user_message>
            """),
        ]
        for (type, field, text) in responses {
            var wrapped = QuestionTracker()
            wrapped.consume(item:["type":"agentMessage","id":"call_1","questions":[["title":"Куда?"]]])
            wrapped.consume(item:["type":type,"status":"accepted",field:[["type":"text","text":text]]])
            XCTAssertEqual(wrapped.pendingCount, 0)
        }
    }

    func testReplyDoesNotDismissOtherQuestion() {
        var tracker = QuestionTracker()
        tracker.consume(item: ["type":"agentMessage","id":"call_2","questions":[["title":"Один?"],["title":"Два?"]]])
        tracker.resolve(callID:"call_2", questionIndex:0)
        XCTAssertEqual(tracker.pendingCount, 1)
        tracker.resolve(callID:"another", questionIndex:1)
        XCTAssertEqual(tracker.pendingCount, 1)
    }

    func testOrdinarySteeringDoesNotPretendToAnswerAWidget() {
        var tracker=QuestionTracker()
        tracker.consume(item:["type":"agentMessage","id":"old","questions":[["title":"Выберите вариант"]]])
        tracker.consume(item:["type":"userMessage","content":[["type":"text","text":"Давай продолжим, используй первый вариант"]]])
        XCTAssertEqual(tracker.pendingCount,1)
        // An ordinary steering message is not an answer to a specific widget.
        tracker.consume(item:["type":"agentMessage","id":"old","questions":[["title":"Выберите вариант"]]])
        XCTAssertEqual(tracker.pendingCount,1)
        tracker.consume(item:["type":"agentMessage","id":"new","questions":[["title":"Новый вопрос"]]])
        XCTAssertEqual(tracker.pendingCount,2)
    }

    func testResumeAfterRegularFollowUp() {
        let first: [String:Any] = ["type":"agentMessage","id":"call_1","questions":[["title":"Первый вопрос"]]]
        let followUp: [String:Any] = ["type":"userMessage","content":[["type":"text","text":"Продолжи сверку файлов"]]]
        let commentary: [String:Any] = ["type":"agentMessage","id":"msg_1","phase":"commentary","text":"Сверяю файлы"]
        var tracker = QuestionTracker()
        tracker.consume(item:first,at:now)
        tracker.consume(item:["type":"agentMessage","id":"msg_0","phase":"commentary","text":"Пока собираю данные"])
        XCTAssertEqual(tracker.pendingCount,1)
        tracker.consume(item:followUp)
        XCTAssertEqual(tracker.pendingCount,1)
        tracker.consume(item:commentary)
        XCTAssertEqual(tracker.pendingCount,0)
        XCTAssertNil(tracker.oldestQuestionAt)
        tracker.consume(item:["type":"agentMessage","id":"call_2","questions":[["title":"Новый вопрос"]]])
        XCTAssertEqual(tracker.firstTitle,"Новый вопрос")

        var quoted = QuestionTracker()
        quoted.consume(item:first)
        quoted.consume(item:["type":"userMessage","content":[["type":"text","text":"Цитата <send_user_message_question_reply>[]</send_user_message_question_reply>"]]])
        quoted.consume(item:commentary)
        XCTAssertEqual(quoted.pendingCount,1)
    }

    func testInterruptedAndUnknownAreNotCompleted() {
        XCTAssertEqual(ActivityPolicy.status(turnStatus:"interrupted", pending:false, lastItemStatus:nil), .paused)
        XCTAssertEqual(ActivityPolicy.status(turnStatus:"failed", pending:false, lastItemStatus:nil), .failed)
        XCTAssertEqual(ActivityPolicy.status(turnStatus:nil, pending:false, lastItemStatus:nil), .unknown)
        XCTAssertEqual(ActivityPolicy.status(turnStatus:"completed", pending:true, lastItemStatus:nil), .completed)
        XCTAssertEqual(ActivityPolicy.status(turnStatus:"inProgress", pending:false, lastItemStatus:"awaitingApproval",execution:.active), .needsInput)
    }

    func testLifecycleStartsOnceAndStopsOnlyAfterLastCodexExit() {
        XCTAssertEqual(LifecyclePolicy.action(codexRunning:true, panelRunning:false), .launchPanel)
        XCTAssertEqual(LifecyclePolicy.action(codexRunning:true, panelRunning:true), .none)
        XCTAssertEqual(LifecyclePolicy.action(codexRunning:false, panelRunning:true), .stopPanel)
        XCTAssertEqual(LifecyclePolicy.action(codexRunning:false, panelRunning:false), .none)
    }

    func testStatusGroupsAndScrollAnchorAcrossGroups() {
        func card(_ id:String,_ seconds:Double,_ state:ActivityState) -> ActivityCard {
            let date = now.addingTimeInterval(-seconds)
            return ActivityCard(threadID:id,title:id,project:"P",summary:"S",state:state,updatedAt:date,turnStartedAt:date)
        }
        let a=card("a",30,.completed), b=card("b",90,.running), old=card("old",90000,.needsInput)
        let sorted=ActivityPolicy.sorted([old,b,a],now:now)
        XCTAssertEqual(sorted.map(\.threadID),["old","b","a"])
        let before=ActivityListLayout(cards:sorted,now:now)
        XCTAssertEqual(before.headers[0],"ждёт вас")
        XCTAssertEqual(before.headers[1],"в работе")
        XCTAssertEqual(before.headers[2],"готово")
        let added=card("new",0,.running)
        let after=ActivityListLayout(cards:ActivityPolicy.sorted([added]+sorted,now:now),now:now)
        let anchored=after.restore(from:before,offset:before.positions[1]+10,viewport:80)
        XCTAssertEqual(anchored,after.positions[2]+10)
        let removed=ActivityListLayout(cards:[old,a],now:now)
        XCTAssertEqual(removed.restore(from:before,offset:before.positions[1]+10,viewport:80),removed.positions[1]+10)
        XCTAssertEqual(ActivityPolicy.age(now.addingTimeInterval(-7200),now:now),"2 ч")
        XCTAssertEqual(ActivityPolicy.age(now.addingTimeInterval(-90000),now:now),"1 д")
    }

    func testReadOnlyAndRepositoryUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func sql(_ name:String,_ sql:String) throws {
            let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3"); p.arguments=[root.appendingPathComponent(name).path]
            let pipe=Pipe(); p.standardInput=pipe; try p.run()
            pipe.fileHandleForWriting.write(Data(sql.utf8)); try pipe.fileHandleForWriting.close(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus,0)
        }
        let old = now.timeIntervalSince1970 - 90000
        try sql("state_5.sqlite", """
          CREATE TABLE projects(id TEXT,name TEXT);
          CREATE TABLE threads(id TEXT,title TEXT,name TEXT,cwd TEXT,source TEXT,agent_path TEXT,updated_at REAL,updated_at_ms REAL,recency_at_ms REAL,project_id TEXT,archived INTEGER);
          INSERT INTO projects VALUES('p','Project');
          INSERT INTO threads VALUES('\(uuid)','Original','Renamed','/tmp/project','vscode',NULL,\(old),NULL,NULL,'p',0);
          """)
        try sql("thread_history_1.sqlite", """
          CREATE TABLE thread_items(thread_id TEXT,rollout_ordinal INTEGER,updated_at_ordinal INTEGER,item_type TEXT,item_json TEXT,created_at_ms REAL,started_at_ms REAL,completed_at_ms REAL,turn_id TEXT);
          CREATE TABLE thread_turns(thread_id TEXT,rollout_ordinal INTEGER,status TEXT,started_at REAL,completed_at REAL,turn_id TEXT,duration_ms REAL);
          INSERT INTO thread_turns VALUES('\(uuid)',1,'inProgress',\(old),NULL,'turn-one',NULL);
          INSERT INTO thread_items VALUES('\(uuid)',1,1,'agentMessage','{"type":"agentMessage","id":"q","questions":[{"title":"Выбор?"}]}',\(old*1000),NULL,NULL,'turn-one');
          """)
        let reader=try SQLiteReader(url:root.appendingPathComponent("state_5.sqlite"))
        do { _ = try reader.query("DELETE FROM threads"); XCTAssertTrue(false) } catch {}
        XCTAssertEqual(try reader.query("SELECT COUNT(*) AS n FROM threads").first?["n"],.integer(1))
        let live=FakeExecution(); live.states[uuid] = .active
        let repository=ActivityRepository(root:root,execution:live)
        let first=try repository.load(now:now)
        XCTAssertEqual(first.cards.count,1)
        XCTAssertEqual(first.cards.first?.title,"Renamed")
        XCTAssertEqual(first.cards.first?.project,"Project")
        XCTAssertEqual(first.cards.first?.state,.needsInput)
        XCTAssertEqual(first.cards.first?.waitingSince,Date(timeIntervalSince1970:old))
        try sql("state_5.sqlite","UPDATE threads SET recency_at_ms=\((old+120)*1000);")
        let stillWaiting = try repository.load(now:now).cards.first
        XCTAssertEqual(stillWaiting?.updatedAt,Date(timeIntervalSince1970:old+120))
        XCTAssertEqual(stillWaiting?.waitingSince,Date(timeIntervalSince1970:old))
        try sql("state_5.sqlite","UPDATE threads SET recency_at_ms=NULL;")
        for period in ActivityPeriod.allCases {
            XCTAssertEqual(try repository.load(now:now,period:period).cards.first?.state,.needsInput)
        }
        // Codex scopes async question widgets to an inProgress turn, not all history.
        try sql("thread_history_1.sqlite","UPDATE thread_turns SET status='completed';")
        XCTAssertEqual(try repository.load(now:now).cards.count,0)
        XCTAssertEqual(try repository.load(now:now,period:.unlimited).cards.first?.state,.completed)
        XCTAssertNil(try repository.load(now:now,period:.unlimited).cards.first?.turnCompletedAt)
        try sql("thread_history_1.sqlite", """
          UPDATE thread_turns SET completed_at=\(old+98), duration_ms=98260;
          UPDATE thread_items SET completed_at_ms=\((old+300)*1000);
          """)
        let completed = try repository.load(now:now,period:.unlimited).cards.first
        XCTAssertEqual(completed?.turnCompletedAt, Date(timeIntervalSince1970:old+98))
        XCTAssertEqual(completed?.turnDuration, 98.26)
        XCTAssertEqual(completed?.updatedAt, Date(timeIntervalSince1970:old+300))
        try sql("thread_history_1.sqlite","UPDATE thread_turns SET duration_ms=NULL;")
        XCTAssertEqual(try repository.load(now:now,period:.unlimited).cards.first?.turnDuration, 98)
        try sql("thread_history_1.sqlite","UPDATE thread_turns SET completed_at=NULL; UPDATE thread_items SET completed_at_ms=NULL;")
        try sql("thread_history_1.sqlite","UPDATE thread_turns SET status='interrupted';")
        XCTAssertEqual(try repository.load(now:now).cards.count,0)
        try sql("thread_history_1.sqlite","UPDATE thread_turns SET status='inProgress';")
        XCTAssertEqual(try repository.load(now:now).cards.first?.state,.needsInput)
        let history=root.appendingPathComponent("thread_history_1.sqlite")
        let temporarilyMissing=root.appendingPathComponent("history-offline.sqlite")
        try FileManager.default.moveItem(at:history,to:temporarilyMissing)
        let offline=try repository.load(now:now)
        XCTAssertEqual(offline.cards.count,1)
        XCTAssertEqual(offline.cards.first?.state,.unknown)
        try FileManager.default.moveItem(at:temporarilyMissing,to:history)
        let reply="<send_user_message_question_reply>[{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"q\\\",0]\",\"question\":\"Выбор?\",\"answer\":\"Да\"}]</send_user_message_question_reply>"
        let quote: [String:Any] = ["type":"userMessage","content":[["type":"text","text":"Цитата:\n" + reply]]]
        let quoteJSON = String(decoding:try JSONSerialization.data(withJSONObject:quote),as:UTF8.self)
            .replacingOccurrences(of:"'",with:"''")
        try sql("thread_history_1.sqlite","INSERT INTO thread_items VALUES('\(uuid)',2,2,'userMessage','\(quoteJSON)',\(old*1000),NULL,NULL,'turn-one');")
        XCTAssertEqual(try repository.load(now:now).cards.first?.state, .needsInput)
        let item:[String:Any] = ["type":"userMessage","content":[["type":"text","text":reply]]]
        let json=String(data:try JSONSerialization.data(withJSONObject:item),encoding:.utf8)!.replacingOccurrences(of:"'",with:"''")
        try sql("thread_history_1.sqlite","UPDATE thread_items SET item_json='\(json)' WHERE thread_id='\(uuid)' AND rollout_ordinal=2;")
        XCTAssertEqual(try repository.load(now:now).cards.count,0)
        let key = RuntimeThreadKey(hostID:"local",threadID:uuid)
        @discardableResult func stream(_ change: [String: Any]) -> RuntimeThreadKey? {
            live.projection.consume([
                "type":"broadcast", "method":"thread-stream-state-changed", "version":11, "sourceClientId":"owner",
                "params":["hostId":"local", "conversationId":uuid, "change":change]
            ], watching:[key])
        }
        let liveQuestion: [String: Any] = ["type":"agentMessage","id":"q","questions":[["title":"Живой вопрос"]]]
        func sameTurnQuestions(_ revision: Int, items: [[String: Any]]) {
            stream(["type":"snapshot","revision":revision,"conversationState":[
                "threadRuntimeStatus":["type":"active"],
                "turns":[["turnId":"turn-one","status":"inProgress","items":items]]
            ]])
        }
        try sql("thread_history_1.sqlite","DELETE FROM thread_items;")
        sameTurnQuestions(1,items:[liveQuestion])
        let waitingOutsidePeriod = try repository.load(now:now).cards.first
        XCTAssertEqual(waitingOutsidePeriod?.state,.needsInput)
        XCTAssertEqual(waitingOutsidePeriod?.summary,"Живой вопрос")
        XCTAssertEqual(waitingOutsidePeriod?.pendingCount,1)
        try sql("thread_history_1.sqlite","INSERT INTO thread_items VALUES('\(uuid)',1,1,'agentMessage','{\"type\":\"agentMessage\",\"id\":\"q\",\"questions\":[{\"title\":\"Живой вопрос\"}]}',\(old*1000),NULL,NULL,'turn-one');")
        let answered: [String: Any] = ["type":"steeringUserMessage","status":"accepted","input":[["type":"text","text":reply]]]
        var queued = answered
        queued["status"] = "pending"
        sameTurnQuestions(2,items:[liveQuestion,queued])
        XCTAssertEqual(try repository.load(now:now).cards.first?.state,.needsInput)
        XCTAssertEqual(stream(["type":"patches","baseRevision":2,"revision":3,"patches":[
            ["op":"replace","path":["turns",0,"items",1,"status"],"value":"accepted"]
        ]]),key)
        sameTurnQuestions(3,items:[answered])
        XCTAssertEqual(try repository.load(now:now).cards.count,0)
        XCTAssertEqual(try repository.load(now:now,period:.unlimited).cards.first?.state,.running)
        try sql("thread_history_1.sqlite","INSERT INTO thread_items VALUES('\(uuid)',2,2,'userMessage','\(json)',\(old*1000),NULL,NULL,'turn-one');")
        live.projection.reset()
        stream(["type":"snapshot", "revision":1, "conversationState":[
            "threadRuntimeStatus":["type":"active", "activeFlags":["waitingOnApproval"]]
        ]])
        for period in ActivityPeriod.allCases {
            let card = try repository.load(now:now,period:period).cards.first
            XCTAssertEqual(card?.state, .needsInput)
            XCTAssertEqual(card?.waitingSince, now)
        }
        stream(["type":"patches", "baseRevision":1, "revision":2, "patches":[
            ["op":"remove", "path":["threadRuntimeStatus", "activeFlags", 0]]
        ]])
        XCTAssertEqual(try repository.load(now:now).cards.count, 0)
        let request: [String: Any] = ["method":"item/permissions/requestApproval","params":["turnId":"turn-one"]]
        stream(["type":"snapshot","revision":3,"conversationState":[
            "threadRuntimeStatus":["type":"active"], "requests":[request]
        ]])
        XCTAssertEqual(try repository.load(now:now).cards.first?.state, .needsInput)
        stream(["type":"patches","baseRevision":3,"revision":4,"patches":[
            ["op":"remove","path":["requests",0]]
        ]])
        XCTAssertEqual(try repository.load(now:now).cards.count, 0)
        stream(["type":"snapshot","revision":5,"conversationState":[
            "threadRuntimeStatus":["type":"active"], "requests":[
                ["method":"item/permissions/requestApproval","params":["turnId":"previous-turn"]],
                ["method":"item/permissions/requestApproval","completed":true,"params":["turnId":"turn-one"]],
            ]
        ]])
        XCTAssertEqual(try repository.load(now:now).cards.count, 0)
        live.projection.reset()
        try sql("thread_history_1.sqlite","INSERT INTO thread_items VALUES('\(uuid)',3,3,'commandExecution','{\"type\":\"commandExecution\",\"status\":\"awaitingApproval\"}',\(old*1000),NULL,NULL,'turn-one');")
        XCTAssertEqual(try repository.load(now:now).cards.first?.state,.needsInput)
        let turn = ["turnId":"turn-one", "status":"inProgress"]
        stream(["type":"snapshot","revision":1,"conversationState":[
            "threadRuntimeStatus":["type":"active"], "turns":[turn], "requests":[request]
        ]])
        XCTAssertEqual(try repository.load(now:now).cards.first?.state,.needsInput)
        stream(["type":"snapshot","revision":2,"conversationState":[
            "threadRuntimeStatus":["type":"active"], "turns":[turn], "requests":[]
        ]])
        XCTAssertEqual(try repository.load(now:now).cards.count,0)
        XCTAssertEqual(try repository.load(now:now,period:.unlimited).cards.first?.state,.running)
        stream(["type":"snapshot","revision":3,"conversationState":[
            "threadRuntimeStatus":["type":"active"], "turns":[["turnId":"different","status":"inProgress"]],
            "requests":[]
        ]])
        XCTAssertEqual(try repository.load(now:now).cards.first?.state,.needsInput)
        live.projection.reset()
        // A newer turn must not inherit a question or approval from a previous turn.
        try sql("thread_history_1.sqlite","INSERT INTO thread_turns VALUES('\(uuid)',4,'inProgress',\(old),NULL,'turn-two',NULL);")
        XCTAssertEqual(try repository.load(now:now).cards.count,0)
        // A mutated existing ordinal must be observed, not just appended items.
        // A metadata update must not revive the old chat or change its activity date.
        live.states[uuid] = .idle
        try sql("state_5.sqlite","UPDATE threads SET updated_at=\(now.timeIntervalSince1970),updated_at_ms=\(now.timeIntervalSince1970*1000);")
        XCTAssertEqual(try repository.load(now:now).cards.count,0)
        let stale=try repository.load(now:now,period:.unlimited).cards.first
        XCTAssertEqual(stale?.state,.paused)
        XCTAssertEqual(stale?.awaitingExecutionConfirmation,true)
        XCTAssertEqual(stale?.updatedAt,Date(timeIntervalSince1970:old))
        live.states.removeAll()
        XCTAssertEqual(try repository.load(now:now,period:.unlimited).cards.first?.state,.unknown)
        try sql("state_5.sqlite","UPDATE threads SET recency_at_ms=\(now.timeIntervalSince1970*1000);")
        try sql("thread_history_1.sqlite","UPDATE thread_turns SET status='interrupted'; DELETE FROM thread_items WHERE rollout_ordinal=3;")
        XCTAssertEqual(try repository.load(now:now).cards.first?.state,.paused)
        // Running order follows turn starts even as internal events advance recency.
        let newer = UUID().uuidString
        let undated = UUID().uuidString
        let time = now.timeIntervalSince1970
        live.states = [uuid: .active, newer: .active, undated: .active]
        try sql("state_5.sqlite", """
            INSERT INTO threads VALUES('\(newer)','Newer',NULL,'/tmp/P','vscode',NULL,0,NULL,NULL,'p',0);
            INSERT INTO threads VALUES('\(undated)','Undated',NULL,'/tmp/P','vscode',NULL,0,NULL,\(time*1000),'p',0);
            """)
        try sql("thread_history_1.sqlite", """
            INSERT INTO thread_turns VALUES('\(uuid)',5,'inProgress',\(time-300),NULL,'older',NULL);
            INSERT INTO thread_turns VALUES('\(newer)',1,'inProgress',NULL,NULL,'newer',NULL);
            INSERT INTO thread_turns VALUES('\(undated)',1,'inProgress',NULL,NULL,'undated',NULL);
            INSERT INTO thread_items VALUES('\(newer)',1,1,'userMessage','{"type":"userMessage"}',\((time-120)*1000),NULL,NULL,'newer');
            INSERT INTO thread_items VALUES('\(uuid)',6,6,'reasoning','{"type":"reasoning"}',\((time-2)*1000),NULL,NULL,'older');
            """)
        let confirmed = try repository.load(now:now).cards
        XCTAssertEqual(confirmed.map(\.threadID), [newer, uuid, undated])
        XCTAssertFalse(confirmed.contains { $0.awaitingExecutionConfirmation })
        try sql("thread_history_1.sqlite", """
            UPDATE thread_turns SET status='completed',completed_at=\(time) WHERE turn_id='older';
            INSERT INTO thread_items VALUES('\(newer)',2,2,'commandExecution','{"type":"commandExecution","status":"awaitingApproval"}',\(time*1000),NULL,NULL,'newer');
            """)
        XCTAssertEqual(try repository.load(now:now).cards.map(\.state), [.needsInput, .running, .completed])

        // Codex has started a new turn, but the SQLite projection still ends at the old one.
        let start = time - 30
        func liveTurn(_ revision: Int, runtime: String, status: String, flags: [String] = []) {
            let turn: [String: Any] = ["turnId":"live", "status":status, "turnStartedAtMs":start*1000, "durationMs":20_000]
            stream(["type":"snapshot", "revision":revision, "conversationState":[
                "threadRuntimeStatus":["type":runtime, "activeFlags":flags], "turns":[turn]
            ]])
        }
        liveTurn(1,runtime:"active",status:"inProgress")
        let recovered = try repository.load(now:now).cards.first { $0.threadID == uuid }
        XCTAssertEqual(recovered?.state,.running)
        XCTAssertEqual(recovered?.turnID,"live")
        XCTAssertEqual(recovered?.turnStartedAt,Date(timeIntervalSince1970:start))
        XCTAssertNil(recovered?.turnCompletedAt)
        func disconnect() {
            _ = live.projection.consume(["type":"broadcast","method":"client-status-changed",
                "params":["status":"disconnected","clientId":"owner"]],watching:[key])
            live.states.removeValue(forKey:uuid)
        }
        disconnect()
        XCTAssertEqual(try repository.load(now:now).cards.first { $0.threadID == uuid }?.state,.unknown)
        liveTurn(2,runtime:"active",status:"inProgress",flags:["waitingOnApproval"])
        XCTAssertEqual(try repository.load(now:now).cards.first { $0.threadID == uuid }?.state,.needsInput)
        liveTurn(3,runtime:"idle",status:"completed")
        let finished = try repository.load(now:now).cards.first { $0.threadID == uuid }
        XCTAssertEqual(finished?.state,.completed)
        XCTAssertEqual(finished?.turnCompletedAt,Date(timeIntervalSince1970:start+20))
        disconnect()
        let disconnected = try repository.load(now:now).cards.first { $0.threadID == uuid }
        XCTAssertEqual(disconnected?.state,.completed)
        XCTAssertEqual(disconnected?.turnCompletedAt,finished?.turnCompletedAt)
        try sql("thread_history_1.sqlite","INSERT INTO thread_turns VALUES('\(uuid)',6,'failed',\(time-5),\(time),'indexed-newer',NULL);")
        XCTAssertEqual(try repository.load(now:now).cards.first { $0.threadID == uuid }?.state,.failed)
        let missing=root.appendingPathComponent("missing.sqlite")
        do { _ = try SQLiteReader(url:missing); XCTAssertTrue(false) } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
    }
}

@main struct RunTests {
    static func main() throws {
        let suite = ActivityCoreTests()
        suite.testFourHourBoundaryAndPendingOverride()
        suite.testAllPeriodsBoundariesAndSavedPreference()
        try suite.testPeriodChangesIncludeLocalAndRemoteHistory()
        try suite.testChatGPTCatalogAndLocalWorkStatuses()
        suite.testRuntimeProjectionAndUnconfirmedTurns()
        suite.testRemoteActivityProjection()
        suite.testThreadURLsValidateUUIDAndEncodeHost()
        suite.testSubagentsAreNotMainChats()
        try suite.testUnansweredQuestionAndExactReply()
        suite.testReplyDoesNotDismissOtherQuestion()
        suite.testOrdinarySteeringDoesNotPretendToAnswerAWidget()
        suite.testResumeAfterRegularFollowUp()
        suite.testInterruptedAndUnknownAreNotCompleted()
        suite.testLifecycleStartsOnceAndStopsOnlyAfterLastCodexExit()
        suite.testStatusGroupsAndScrollAnchorAcrossGroups()
        try suite.testReadOnlyAndRepositoryUpdates()
        try suite.testTokenUsageFollowsProjectedTurnBoundaries()
        if failures > 0 { exit(1) }
        print("17 behavior tests passed")
    }
}
