import ActivityPanelStyle
import AppKit
import ActivityCore
import ServiceManagement
import SwiftUI

final class FakeLoginService: LoginService {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var fail = false
    var suspended = false
    var continuation: CheckedContinuation<Void,Never>?
    func register() throws {
        if fail { throw NSError(domain:"Test",code:1) }
        registrations += 1; status = .enabled
    }
    func unregister() async throws {
        removals += 1
        if suspended { await withCheckedContinuation { continuation = $0 } }
        if fail { throw NSError(domain:"Test",code:2) }
        status = .notRegistered
    }
}
private final class HeaderTestPanel: NSPanel {
    var dragCount = 0

    override func performDrag(with event: NSEvent) {
        dragCount += 1
    }
}

private final class ActiveExecution: ExecutionObserving {
    var revision: UInt64 { 0 }

    func observe(threadIDs: Set<String>) -> [String: LocalExecution] {
        Dictionary(uniqueKeysWithValues: threadIDs.map { ($0, LocalExecution(status: .active)) })
    }
}

private final class FakeLauncherService: LauncherService {
    var codexRunning = true
    var panelRunning = false
    var opens = 0
    var stops = 0
    var stoppedApplication: NSRunningApplication?
    var completion: ((NSRunningApplication?) -> Void)?

    func openPanel(completion: @escaping (NSRunningApplication?) -> Void) {
        precondition(self.completion == nil, "Only one launch may be in flight")
        opens += 1
        self.completion = completion
    }

    func stopPanels(including opened: NSRunningApplication?) {
        stops += 1
        stoppedApplication = opened
        panelRunning = false
    }

    func finish(_ application: NSRunningApplication? = nil) {
        let callback = completion!
        completion = nil
        callback(application)
    }
}

@main struct PanelRegressionTests {
    @MainActor private static func testPeriodPreferenceIsolation() {
        let sharedPeriod = UserDefaults.standard.object(forKey: "trackingHours") as? Int
        let sharedWidth = UserDefaults.standard.object(forKey: "widthMM") as? Double
        let names = (0..<3).map { _ in "io.github.moky-me.CodexActivity.period.\(UUID().uuidString)" }
        let stores = names.map { UserDefaults(suiteName: $0)! }
        defer {
            for (name, store) in zip(names, stores) { store.removePersistentDomain(forName: name) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        func model(_ store: UserDefaults) -> PanelModel {
            PanelModel(loginService: FakeLoginService(), preferences: store,
                       repository: ActivityRepository(root: root))
        }
        stores[0].set(12, forKey: "trackingHours")
        stores[1].set(24, forKey: "trackingHours")
        stores[0].set(27, forKey: "widthMM")
        stores[1].set(30, forKey: "widthMM")
        let first = model(stores[0])
        precondition(first.period == .twelveHours, "The period comes from the injected store")
        precondition(stores[0].object(forKey: "widthMM") == nil &&
                     stores[1].object(forKey: "widthMM") != nil, "Migration only changes its own store")
        let second = model(stores[1])
        precondition(second.period == .day && stores[1].object(forKey: "widthMM") == nil)
        first.setPeriod(.eightHours)
        precondition(stores[0].integer(forKey: "trackingHours") == 8 &&
                     stores[1].integer(forKey: "trackingHours") == 24)
        precondition(model(stores[0]).period == .eightHours, "The selected period survives recreation")
        second.setPeriod(.unlimited)
        precondition(model(stores[1]).period == .unlimited &&
                     model(stores[0]).period == .eightHours)
        precondition(model(stores[2]).period == .fourHours, "Missing preference uses four hours")
        stores[2].set(7, forKey: "trackingHours")
        precondition(model(stores[2]).period == .fourHours, "Invalid preference uses four hours")
        precondition(UserDefaults.standard.object(forKey: "trackingHours") as? Int == sharedPeriod &&
                     UserDefaults.standard.object(forKey: "widthMM") as? Double == sharedWidth,
                     "Injected settings must not write to the shared domain")
    }

    @MainActor private static func testLauncherRetries() async throws {
        @MainActor func afterLaunchCallback(_ action: @escaping () -> Void) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    action()
                    continuation.resume()
                }
            }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("The launch callback or retry did not finish")
        }
        let service = FakeLauncherService()
        let launcher = Launcher(service: service, retryDelay: 0.02)
        launcher.reconcile()
        launcher.reconcile()
        precondition(service.opens == 1, "Workspace events must not create parallel launches")
        service.finish()
        try await waitUntil { service.opens == 2 }
        launcher.reconcile()
        precondition(service.opens == 2)
        service.finish()
        try await waitUntil { service.opens == 3 }
        service.finish()
        try await Task.sleep(for: .milliseconds(80))
        launcher.reconcile()
        precondition(service.opens == 3, "Three failed attempts exhaust the budget")
        service.codexRunning = false
        launcher.reconcile()
        service.codexRunning = true
        launcher.reconcile()
        precondition(service.opens == 4, "A new Codex session gets a fresh launch budget")
        service.panelRunning = true
        service.finish()
        try await Task.sleep(for: .milliseconds(80))
        launcher.reconcile()
        precondition(service.opens == 4, "A running panel cancels retries")

        let returned = FakeLauncherService()
        let returnedLauncher = Launcher(service: returned, retryDelay: 0.02)
        returnedLauncher.reconcile()
        returned.finish(.current)
        try await Task.sleep(for: .milliseconds(80))
        precondition(returned.opens == 1, "The returned process confirms success before workspace registration")

        let interrupted = FakeLauncherService()
        let interruptedLauncher = Launcher(service: interrupted, retryDelay: 0.02)
        interruptedLauncher.reconcile()
        interrupted.codexRunning = false
        interruptedLauncher.reconcile()
        // LaunchServices may return the process before runningApplications includes it.
        interrupted.finish(.current)
        try await waitUntil { interrupted.stoppedApplication != nil }
        try await Task.sleep(for: .milliseconds(80))
        precondition(interrupted.stoppedApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier &&
                     interrupted.opens == 1, "A late result must be stopped after Codex exits")

        let cancelled = FakeLauncherService()
        let cancelledLauncher = Launcher(service: cancelled, retryDelay: 0.05)
        cancelledLauncher.reconcile()
        cancelled.finish()
        await afterLaunchCallback {
            cancelled.codexRunning = false
            cancelledLauncher.reconcile()
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(cancelled.opens == 1, "Codex exit cancels a scheduled retry")

        let external = FakeLauncherService()
        let externalLauncher = Launcher(service: external, retryDelay: 0.05)
        externalLauncher.reconcile()
        external.finish()
        await afterLaunchCallback {
            external.panelRunning = true
            externalLauncher.reconcile()
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(external.opens == 1, "A panel opened elsewhere cancels a scheduled retry")
    }

    @MainActor private static func testReadFailureAndRecovery() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root.appendingPathComponent("sqlite"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let suite = "io.github.moky-me.CodexActivity.read-failure.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let runningID = UUID().uuidString
        let workID = UUID().uuidString
        let completedID = UUID().uuidString
        let now = Date().timeIntervalSince1970

        func sql(_ database: String, _ statement: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [root.appendingPathComponent(database).path, statement]
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Fixture SQL must succeed")
        }
        try sql("state_5.sqlite", """
            CREATE TABLE projects(id TEXT,name TEXT);
            CREATE TABLE threads(id TEXT,title TEXT,name TEXT,cwd TEXT,source TEXT,agent_path TEXT,
                recency_at_ms REAL,project_id TEXT,archived INTEGER,originator TEXT,tokens_used INTEGER);
            INSERT INTO threads VALUES
                ('\(runningID)','Codex',NULL,'/fixture','cli',NULL,\(now*1000),NULL,0,NULL,1000),
                ('\(workID)','Work',NULL,'/fixture','cli',NULL,\(now*1000),NULL,0,'codex_work_desktop',2000),
                ('\(completedID)','Done',NULL,'/fixture','cli',NULL,\(now*1000),NULL,0,NULL,3000);
            """)
        try sql("thread_history_1.sqlite", """
            CREATE TABLE thread_turns(thread_id TEXT,rollout_ordinal INTEGER,status TEXT,
                started_at REAL,completed_at REAL,turn_id TEXT,duration_ms REAL);
            CREATE TABLE thread_items(thread_id TEXT,rollout_ordinal INTEGER,item_type TEXT,
                item_json TEXT,created_at_ms REAL,started_at_ms REAL,completed_at_ms REAL,turn_id TEXT);
            INSERT INTO thread_turns VALUES
                ('\(runningID)',1,'inProgress',\(now-120),NULL,'codex-turn',NULL),
                ('\(workID)',1,'inProgress',\(now-90),NULL,'work-turn',NULL),
                ('\(completedID)',1,'completed',\(now-180),\(now-60),'done-turn',120000);
            """)
        try sql("sqlite/codex.db", """
            CREATE TABLE local_thread_catalog(host_id TEXT,thread_id TEXT,display_title TEXT,cwd TEXT,
                source_detail TEXT,source_recency_at REAL,missing_candidate INTEGER);
            CREATE TABLE local_thread_catalog_hosts(host_id TEXT,host_kind TEXT);
            """)
        let repository = ActivityRepository(root: root, execution: ActiveExecution())
        let model = PanelModel(loginService: FakeLoginService(), preferences: preferences, repository: repository)
        func reload(force: Bool = true) async throws {
            model.loading = true
            model.refresh(force: force)
            for _ in 0..<250 {
                if !model.loading { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("The read must finish")
        }
        try await reload()
        precondition(model.notice == nil && model.cards.filter { $0.state == .running }.count == 2)
        precondition(model.cards.first { $0.threadID == workID }?.source == .work)
        let caption = model.runningVerb(for: model.cards.first { $0.threadID == runningID }!)
        let terminal = model.cards.first { $0.threadID == completedID }!
        let remote = ActivityCard(threadID: UUID().uuidString, hostID: "ssh:fixture", title: "Remote",
            project: "Fixture", summary: "Old summary", state: .running, updatedAt: Date(),
            turnStartedAt: Date(), awaitingExecutionConfirmation: true, turnID: "remote-turn")
        let waiting = ActivityCard(threadID: UUID().uuidString, title: "Question", project: "Fixture",
            summary: "Confirmed question", state: .needsInput, updatedAt: Date(), pendingCount: 1,
            waitingSince: Date(), turnID: "question-turn")
        model.cards += [remote, waiting]
        for state in [ActivityState.failed, .paused, .unknown] {
            model.cards.append(ActivityCard(threadID: UUID().uuidString, title: "Retained", project: "Fixture",
                summary: state.label, state: state, updatedAt: Date()))
        }
        let previous = model.cards
        for host in ["chatgpt:fixture:user"] {
            model.cards.append(ActivityCard(threadID: UUID().uuidString, hostID: host, title: "Account",
                project: "Fixture", summary: "Account", state: .running, updatedAt: Date()))
        }
        let database = root.appendingPathComponent("state_5.sqlite")
        let offline = root.appendingPathComponent("offline.sqlite")
        try files.moveItem(at: database, to: offline)
        try await reload()
        precondition(model.notice != nil && !files.fileExists(atPath: database.path))
        precondition(model.cards.count == previous.count && !model.cards.contains { $0.isChatGPTHosted })
        precondition(!model.cards.contains { $0.state == .running })
        precondition(model.cards == ActivityPolicy.sorted(model.cards, now: Date()),
                     "Downgraded cards must move into the existing other group")
        for card in previous {
            let retained = model.cards.first { $0.id == card.id }!
            if card.state == .running {
                precondition(retained.state == .unknown && retained.state.group == .other)
                precondition(retained.summary == "источник данных недоступен" && !retained.awaitingExecutionConfirmation)
                precondition(retained.url == card.url && retained.updatedAt == card.updatedAt &&
                    retained.turnStartedAt == card.turnStartedAt && retained.turnID == card.turnID &&
                    retained.tokenUsage == card.tokenUsage && retained.source == card.source)
            } else {
                precondition(retained == card, "Confirmed completion and outstanding requests must be retained")
            }
        }
        let unavailable = model.cards
        try await reload(force: false)
        precondition(model.cards == unavailable, "Repeated failures must keep the fallback stable")
        try files.moveItem(at: offline, to: database)
        try await reload(force: false)
        precondition(model.notice == nil && model.cards.count == 3)
        precondition(model.cards.first { $0.threadID == runningID }?.state == .running)
        precondition(model.runningVerb(for: model.cards.first { $0.threadID == runningID }!) == caption)
        precondition(model.cards.first { $0.threadID == completedID } == terminal)
        try sql("thread_history_1.sqlite", """
            UPDATE thread_turns SET status='completed',completed_at=\(now),duration_ms=120000
            WHERE thread_id='\(runningID)';
            """)
        try await reload()
        let finished = model.cards.first { $0.threadID == runningID }!
        precondition(finished.state == .completed && finished.turnDuration == 120)
        try files.moveItem(at: database, to: offline)
        try await reload()
        precondition(model.cards.first { $0.threadID == runningID } == finished,
                     "A later read failure must preserve confirmed completion")
    }

    @MainActor private static func testHeaderDragAndZoom(model: PanelModel, width: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let original = NSRect(x: visible.minX + 30, y: visible.minY + 60, width: width, height: 410)
        let panel = HeaderTestPanel(
            contentRect: original,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        let delegate = AppDelegate()
        panel.delegate = delegate
        panel.minSize = NSSize(width: original.width, height: 260)
        panel.maxSize = NSSize(width: original.width, height: visible.height)
        let host = NSHostingView(rootView: PanelView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        host.layoutSubtreeIfNeeded()

        func hit(at location: NSPoint) -> NSView? {
            host.hitTest(host.superview!.convert(location, from: nil))
        }
        func send(_ type: NSEvent.EventType, count: Int, to view: NSView?, at location: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1
            )!
            switch type {
            case .leftMouseDown: view?.mouseDown(with: event)
            case .leftMouseDragged: view?.mouseDragged(with: event)
            case .leftMouseUp: view?.mouseUp(with: event)
            default: preconditionFailure("Unexpected test event")
            }
        }
        func click(_ count: Int, at location: NSPoint) {
            let view = hit(at: location)
            send(.leftMouseDown, count: count, to: view, at: location)
            send(.leftMouseUp, count: count, to: view, at: location)
        }

        let top = NSPoint(x: 22, y: host.bounds.height - 6)
        click(1, at: top)
        precondition(panel.dragCount == 0, "A stationary click must not start a window drag")
        for start in [top, NSPoint(x: 22, y: host.bounds.height - 22)] {
            let view = hit(at: start)
            send(.leftMouseDown, count: 1, to: view, at: start)
            send(.leftMouseDragged, count: 1, to: view, at: NSPoint(x: start.x+10, y: start.y))
            send(.leftMouseUp, count: 1, to: view, at: start)
        }
        precondition(panel.dragCount == 2, "Drag must work on the blank strip and title")
        let menu = hit(at: NSPoint(x: width - 20, y: host.bounds.height - 20)) as? NSButton
        precondition(menu?.accessibilityLabel() == "настройки панели",
                     "The settings menu must remain above the drag surface")
        let period = hit(at: NSPoint(x: 35, y: host.bounds.height - 46)) as? NSButton
        precondition(period?.accessibilityLabel() == "период наблюдения" &&
                     period?.accessibilityValue() as? String == "4 часа",
                     "The period needs its own native control and accessible value")
        if let menu, let period {
            let menuFrame = menu.convert(menu.bounds, to: host)
            let periodFrame = period.convert(period.bounds, to: host)
            precondition(menuFrame.intersection(periodFrame).isEmpty,
                         "The menu and period hit areas must not overlap")
        }

        click(1, at: top)
        click(2, at: top)
        precondition(panel.frame == NSRect(x: original.minX, y: visible.minY, width: original.width, height: visible.height),
                     "Double click must fill the available height while preserving width and horizontal position")
        precondition(panel.dragCount == 2, "The double click must not hand either click to window dragging")
        host.layoutSubtreeIfNeeded()
        let expandedTop = NSPoint(x: 22, y: host.bounds.height - 6)
        click(1, at: expandedTop)
        click(2, at: expandedTop)
        precondition(panel.frame == original, "Second double click must restore the user frame")
    }

    @MainActor private static func testRunningCaptions() {
        let suite = "io.github.moky-me.CodexActivity.captions.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let model = PanelModel(loginService:FakeLoginService(),preferences:preferences)
        let start = Date(timeIntervalSince1970:1_800_000_000)
        func card(_ index: Int, state: ActivityState = .running, turn: String? = "first",
                  shift: TimeInterval = 0) -> ActivityCard {
            ActivityCard(threadID:String(index),title:"Test",project:"Test",summary:"",state:state,
                         updatedAt:start.addingTimeInterval(10),turnStartedAt:start.addingTimeInterval(shift),turnID:turn)
        }
        let count = 111
        let running = (0..<count).map { card($0) }
        let referenceSuite = suite + ".reference"
        let referencePreferences = UserDefaults(suiteName:referenceSuite)!
        defer { referencePreferences.removePersistentDomain(forName:referenceSuite) }
        let reference = PanelModel(loginService:FakeLoginService(),preferences:referencePreferences)
        reference.cards = running
        let verbs = running.map { reference.runningVerb(for:$0) }
        precondition(Set(verbs).count == count && !verbs.contains("Делает"),
                     "The full cycle must assign 111 distinct captions before overflow")
        let added = ["Воркает", "Джобает", "Фиксит", "Пушит", "Дебажит", "Факапит",
                     "Фармит", "Ресерчит", "Чиллит", "Рофлит", "Питчит", "Билдит"]
        precondition(Set(added).isSubset(of: Set(verbs)), "The cycle must include all requested words")
        model.cards = Array(running.prefix(10))
        precondition(model.cards.map { model.runningVerb(for:$0) } == Array(verbs.prefix(10)),
                     "New turns must use the given order")
        let restarted = PanelModel(loginService:FakeLoginService(),preferences:preferences)
        restarted.cards = [card(10)]
        precondition(restarted.runningVerb(for:card(10)) == verbs[10],
                     "Restart must resume the cycle even when earlier words are free")
        restarted.cards = running
        precondition(running.map { restarted.runningVerb(for:$0) } == verbs,
                     "Simultaneous turns must use all 111 different words in order")
        restarted.cards = Array(running.reversed()) + [card(count)]
        precondition(running.map { restarted.runningVerb(for:$0) } == verbs &&
                     restarted.runningVerb(for:card(count)) == "Делает",
                     "Reordering must not reshuffle words and overflow must use the neutral caption")
        restarted.cards = [card(count+1)]
        precondition(restarted.runningVerb(for:card(count+1)) == verbs[0], "The cycle wraps after the last word")
        restarted.cards = [card(0,state:.needsInput),card(count+2)]
        precondition(restarted.runningVerb(for:card(count+2)) != verbs[0], "A waiting turn keeps its reservation")
        restarted.cards = [card(0,shift:0.25),card(count+2)]
        precondition(restarted.runningVerb(for:card(0)) == verbs[0], "The same turn keeps its verb on resume")
        let next = card(0,turn:"second",shift:120)
        restarted.cards = [next]
        precondition(restarted.runningVerb(for:next) != verbs[0], "A new turn should avoid the previous word")
        let withoutID = card(count+3,turn:nil)
        restarted.cards = [withoutID]
        let provisional = restarted.runningVerb(for:withoutID)
        let identified = card(count+3,shift:0.25)
        restarted.cards = [identified]
        precondition(provisional != "Делает" && restarted.runningVerb(for:identified) == provisional,
                     "A later turn ID must preserve the assignment made from its start time")
        precondition(CardView.shortRunningDuration(86_340) == "23 ч",
                     "A narrow caption retains elapsed hours when minutes do not fit")
        precondition(CardView.tightRunningDuration(660) == "11м")
        let legacy = #"{"nextVerbIndex":15,"entries":{"local:3":{"turnID":"first","verb":"Создает"}}}"#
        preferences.set(Data(legacy.utf8),forKey:"runningCaptions")
        let migrated = PanelModel(loginService:FakeLoginService(),preferences:preferences)
        migrated.cards = [card(3), card(count+4)]
        precondition(migrated.runningVerb(for:card(3)) == "Создаёт" &&
                     migrated.runningVerb(for:card(count+4)) == verbs.first(where: { $0 != "Создаёт" }),
                     "Legacy snapshots keep current words and start the new order from the beginning")
        let previousOrder = #"{"nextCaptionIndex":15,"entries":{"local:3":{"turnID":"first","verb":"Телодвижется"},"local:4":{"turnID":"first","verb":"Колдует"}}}"#
        preferences.set(Data(previousOrder.utf8),forKey:"runningCaptions")
        let updated = PanelModel(loginService:FakeLoginService(),preferences:preferences)
        updated.cards = [card(3), card(4)]
        precondition(updated.runningVerb(for:card(3)) == verbs.first(where: { $0 != "Колдует" }) &&
                     updated.runningVerb(for:card(4)) == "Колдует",
                     "Changing the order replaces excluded words and preserves allowed assignments")
        let updatedRestart = PanelModel(loginService:FakeLoginService(),preferences:preferences)
        updatedRestart.cards = [card(count+5)]
        precondition(updatedRestart.runningVerb(for:card(count+5)) == verbs[verbs[0] == "Колдует" ? 2 : 1],
                     "The new cursor persists after migration")
        let currentOrder = #"{"nextCaptionIndexV4":15,"entries":{"local:4":{"turnID":"first","verb":"Колдует"}}}"#
        preferences.set(Data(currentOrder.utf8),forKey:"runningCaptions")
        let extended = PanelModel(loginService:FakeLoginService(),preferences:preferences)
        extended.cards = [card(4),card(count+6)]
        precondition(extended.runningVerb(for:card(4)) == "Колдует" &&
                     extended.runningVerb(for:card(count+6)) == verbs.first(where: { $0 != "Колдует" }),
                     "Reshuffling starts a fresh cursor and keeps assigned words")
    }

    @MainActor private static func testGroupMoveAtScrollLimit(model: PanelModel) {
        func card(_ id: String, _ state: ActivityState) -> ActivityCard {
            ActivityCard(threadID:id, title:id, project:"Test", summary:"Test",
                         state:state, updatedAt:.now)
        }
        let ready = (1...4).map { card("Ready \($0)", .completed) }
        let moving = card("Moving", .paused)
        model.cards = ready + [moving]
        let host = NSHostingView(rootView: NativeCardScroll(model: model))
        host.sizingOptions = []
        host.frame = NSRect(x:0, y:0, width:150, height:300)

        func update() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
            host.layoutSubtreeIfNeeded()
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in:$0) }.first
        }
        update()
        guard let scroll = scrollView(in:host),
              let document = scroll.documentView as? NSHostingView<CardList> else {
            preconditionFailure("Expected the real card scroll and SwiftUI document")
        }
        let presentation = document.rootView.presentation
        let layout = presentation.snapshot.layout
        let sameGroupGap = layout.positions[1] - layout.cardTop(at:0) - layout.height(for:ready[0])
        let nextGroupGap = layout.positions[4] - layout.cardTop(at:3) - layout.height(for:ready[3])
        precondition(sameGroupGap == 8 && nextGroupGap == 12,
                     "The next section must have more space than adjacent cards")
        let bottom = document.frame.height - scroll.contentSize.height
        precondition(bottom > 0)
        scroll.contentView.scroll(to:NSPoint(x:0,y:bottom))

        model.cards = ready.dropLast() + [card(moving.threadID,.completed), ready.last!]
        update()
        let after = presentation.snapshot
        precondition(after.cards[3].id == moving.id && after.cards[3].state == .completed)
        let removedSectionHeight = nextGroupGap - sameGroupGap + ActivityListLayout.headingHeight
        precondition(abs(scroll.contentView.bounds.minY - (bottom - removedSectionHeight)) < 0.5,
                     "Removing the last section must clamp the scroll position to the new bottom")
        precondition(after.animateMoves,
                     "A surviving card must animate into the new group even when the scroll position clamps")
        precondition(after.groupMoves == [moving.id])
        precondition(abs(after.animationOrigin - (scroll.contentView.bounds.minY - bottom)) < 0.5,
                     "The SwiftUI animation must start at the same screen position despite the AppKit scroll adjustment")
        let crossing = after.statusTransitions[moving.id]
        precondition(crossing?.previous.state == .paused, "A moving card must start with its previous status")
        precondition(crossing?.progress(at:0) == 0 && crossing?.progress(at:1) == 1,
                     "The status crossfade must settle at the same endpoints as the card")

        let beforeRemoval = scroll.contentView.bounds.minY
        model.cards.removeLast()
        update()
        let trimmed = presentation.snapshot
        let trimmedY = scroll.contentView.bounds.minY
        precondition(trimmedY < beforeRemoval && trimmed.groupMoves.isEmpty)
        precondition(trimmed.animateMoves &&
                     abs(trimmed.animationOrigin - after.animationOrigin - (trimmedY - beforeRemoval)) < 0.5,
                     "Expiration at the scroll limit must preserve animation coordinates in any group")

        model.cards = [card("Single", .running)]
        update()
        let stationary = presentation.snapshot
        model.cards = [card("Single", .needsInput)]
        update()
        let waiting = presentation.snapshot
        precondition(stationary.layout.cardTop(at:0) == waiting.layout.cardTop(at:0))
        precondition(waiting.statusTransitions["local:Single"]?.progress(at:0.5) == 0.5,
                     "Changing groups in place must still crossfade the status")

        model.cards = [card("Single", .running)]
        update()
        let returning = presentation.snapshot.statusTransitions["local:Single"]
        precondition(returning?.previous.state == .needsInput,
                     "The return must start from the waiting status")
        precondition(returning?.progress(at:1.0625) == 0.0625 && returning?.progress(at:1.9375) == 0.9375,
                     "A stationary return must use the full animation phase for the status roll")

        model.cards = [card("Single", .unknown)]
        update()
        let unknown = presentation.snapshot
        model.cards = [card("Single", .failed)]
        update()
        let failed = presentation.snapshot
        precondition(unknown.layout.headers == failed.layout.headers && !failed.animateMoves)
        guard let failure = failed.statusTransitions["local:Single"] else {
            preconditionFailure("A status change inside «Другое» must animate without a layout change")
        }
        precondition(failure.previous.state == .unknown && failure.progress(at:failure.phaseTarget - 0.75) == 0.25,
                     "A status change within a group must use the same full transition as an in-place group change")

        model.cards = [card("Single", .failed)]
        update()
        precondition(presentation.snapshot.statusTransitions["local:Single"]?.phaseTarget == failure.phaseTarget,
                     "Refreshing timestamps without a new status must not replay the transition")

        let metered = ActivityCard(threadID:"Metered",title:"Metered",project:"Test",summary:"Test",
                                   state:.completed,updatedAt:.now,tokenUsage:.init(turn:120,chat:240))
        model.cards = ready + [metered]
        update()
        let shownHeight = document.frame.height
        let shownBottom = shownHeight - scroll.contentSize.height
        scroll.contentView.scroll(to:NSPoint(x:0,y:shownBottom))
        model.setShowsTokens(false)
        update()
        precondition(document.frame.height == shownHeight - ActivityListLayout.tokenRowHeight &&
                     scroll.contentView.bounds.minY <= document.frame.height - scroll.contentSize.height &&
                     presentation.snapshot.cards.last?.tokenUsage == metered.tokenUsage,
                     "Hiding tokens must resize the existing scroll document without dropping the totals")
        model.setShowsTokens(true)
        update()
        precondition(document.frame.height == shownHeight, "Showing tokens must restore the row immediately")

        let threadID = UUID().uuidString
        let localWork = ActivityCard(threadID:threadID,source:.work,title:"Local Work",project:"Test",
                                     summary:"",state:.completed,updatedAt:.now)
        let cloudWork = ActivityCard(threadID:threadID,hostID:"chatgpt:account:user",source:.work,
                                     title:"Cloud Work",project:"Test",summary:"",state:.unknown,updatedAt:.now)
        let chatGPT = ActivityCard(threadID:UUID().uuidString,hostID:"chatgpt:account:user",source:.chatGPT,
                                   title:"ChatGPT",project:"Test",summary:"",state:.unknown,updatedAt:.now)
        let mixedCards = ready + [localWork, cloudWork, chatGPT]
        model.cards = mixedCards
        update()
        precondition(presentation.snapshot.cards == mixedCards)
        model.setShowsCloudChats(false)
        update()
        precondition(presentation.snapshot.cards == ready + [localWork],
                     "Hiding hosted chats must keep local Work even when both share a thread ID")
        model.cards = [cloudWork, chatGPT]
        update()
        precondition(presentation.snapshot.cards.isEmpty, "Hosted chats must stay hidden when the catalog refreshes")
        model.setShowsCloudChats(true)
        update()
        precondition(presentation.snapshot.cards == [cloudWork, chatGPT],
                     "Showing hosted chats must restore the latest catalog without another refresh")
    }

    @MainActor private static func testCardClock() {
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let running = ActivityCard(threadID:"new-turn",title:"clock",project:"fixture",summary:"fixed",
            state:.running,updatedAt:now,turnStartedAt:now.addingTimeInterval(25))
        let current = now.addingTimeInterval(35)
        let ticks = Array(CardView.clockSchedule(for:running).entries(from:current,mode:.normal).prefix(2))
        precondition(ticks == [now.addingTimeInterval(25),now.addingTimeInterval(85)],
                     "The first minute expires at the turn boundary, not at the next wall-clock minute")
        precondition(CardTokenRow.Values(card:running,now:max(ticks[0],current)).isWaiting)
        precondition(!CardTokenRow.Values(card:running,now:ticks[1]).isWaiting)
        let card = ActivityCard(threadID:"clock", title:"clock", project:"fixture", summary:"fixed",
                                state:.unknown, updatedAt:now.addingTimeInterval(-57))
        let host = NSHostingView(rootView:CardView(card:card, visible:true, action:{}, now:now).frame(width:150))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:150,height:160), styleMask:.borderless,
                              backing:.buffered, defer:false)
        window.contentView = host
        func bitmap() -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
            host.cacheDisplay(in:host.bounds,to:bitmap)
            return bitmap.representation(using:.png,properties:[:])!
        }
        let before = bitmap()
        host.rootView = CardView(card:card, visible:true, action:{}, now:now.addingTimeInterval(5)).frame(width:150)
        precondition(bitmap() != before, "An unchanged card must render the new clock, without a new snapshot")
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let midnight = calendar.startOfDay(for:now).addingTimeInterval(86400)
        precondition(CardView.completionLabel(now,now:midnight.addingTimeInterval(-1),calendar:calendar) !=
                     CardView.completionLabel(now,now:midnight,calendar:calendar))
        precondition(!window.isVisible)
    }

    private static func testTokenWaiting() {
        let start = Date(timeIntervalSince1970:1_800_000_000)
        func values(host: String = "local", state: ActivityState = .running,
                    age: TimeInterval = 0, usage: ActivityTokenUsage? = nil) -> CardTokenRow.Values {
            let card = ActivityCard(threadID:"Token",hostID:host,title:"Test",project:"Test",summary:"",
                                    state:state,updatedAt:start,turnStartedAt:start,tokenUsage:usage)
            return CardTokenRow.Values(card:card,now:start.addingTimeInterval(age))
        }

        precondition(values().turn == .waiting && values().chat == .waiting)
        precondition(values(usage:.init(turn:nil,chat:240)).turn == .waiting &&
                     values(usage:.init(turn:nil,chat:240)).chat == .count(240))
        precondition(!values(usage:.init(turn:0,chat:240)).isWaiting, "Zero is a received count")
        precondition(!values(age:60).isWaiting && !values(state:.completed).isWaiting)
        precondition(values(host:"ssh:host").turn == .unavailable && values(host:"ssh:host").chat == .waiting)
        precondition(values().details.contains("ожидаются данные") && values(age:60).details.contains("нет данных"))
    }

    @MainActor static func main() async throws {
        testCardClock()
        testTokenWaiting()
        let defaults = UserDefaults.standard
        let spacesKey = "showOnAllSpaces"
        let originalSetting = defaults.object(forKey: spacesKey)
        defer { defaults.set(originalSetting, forKey: spacesKey) }
        defaults.removeObject(forKey: spacesKey)
        func newPanel() -> ActivityWindow {
            ActivityWindow(contentRect:NSRect(x:0,y:0,width:150,height:300),
                           styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        }
        let panel = newPanel()
        precondition(panel.allowsToolTipsWhenApplicationIsInactive,
                     "The panel must offer tooltips while Codex is active")
        precondition(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.level == .normal,
                     "A new panel must default to all Spaces at the normal window level")
        let spacesItem = panel.allSpacesMenuItem()
        precondition(spacesItem.state == .on)
        precondition(NSApplication.shared.sendAction(spacesItem.action!, to: spacesItem.target, from: spacesItem))
        precondition(panel.allSpacesMenuItem().state == .off &&
                     panel.collectionBehavior.contains(.managed) && panel.level == .normal,
                     "Turning off all Spaces must take effect in place and keep the normal level")
        let reopened = newPanel()
        let restoredItem = reopened.allSpacesMenuItem()
        precondition(restoredItem.state == .off, "A new panel must restore the single-Space preference")
        precondition(NSApplication.shared.sendAction(restoredItem.action!, to: restoredItem.target, from: restoredItem))
        precondition(newPanel().allSpacesMenuItem().state == .on, "Turning on all Spaces must also persist")
        precondition(ActivityState.unknown.label == "нет статуса",
                     "All representations must use the same unknown-status label")
        precondition([ActivityState.failed,.paused,.unknown].allSatisfy {
            PanelPalette.statusStripe($0.group,.dark) == PanelPalette.muted(.dark).opacity(0.45)
        }, "Every status in Other must use the same neutral stripe")
        let sizes: [(CGFloat,CGFloat,CGFloat)] = [
            (1728,344.245,150), (1512,302.4,131), (1280,289.6,124),
            (1280,0,124), (1728,0,150)
        ]
        for (points,mm,expected) in sizes {
            precondition(ActivityWindow.width(screenWidth:points,physicalWidth:mm,targetMM:30) == expected,
                         "Display adaptation must preserve a readable point width")
        }
        precondition(CardView.completedDuration(10_572.784) == "2 ч" &&
                     CardView.spokenDuration(10_572.784).contains("56 минут"),
                     "Completed cards must retain minute precision for the duration tooltip")
        let name="io.github.moky-me.CodexActivity.tests.\(UUID().uuidString)"
        let prefs=UserDefaults(suiteName:name)!
        defer { prefs.removePersistentDomain(forName:name) }
        let service=FakeLoginService()
        let model=PanelModel(loginService:service,preferences:prefs)
        precondition(model.showsTokens, "Tokens must default to visible")
        model.setShowsTokens(false)
        precondition(!PanelModel(loginService:service,preferences:prefs).showsTokens,
                     "Hidden tokens must stay hidden after restart")
        model.setShowsTokens(true)
        precondition(PanelModel(loginService:service,preferences:prefs).showsTokens,
                     "Showing tokens again must persist")
        precondition(model.showsCloudChats, "Hosted chats must default to visible")
        model.setShowsCloudChats(false)
        precondition(!PanelModel(loginService:service,preferences:prefs).showsCloudChats,
                     "Hiding hosted chats must persist")
        model.setShowsCloudChats(true)
        precondition(PanelModel(loginService:service,preferences:prefs).showsCloudChats,
                     "Showing hosted chats again must persist")
        model.notice = "Данные недоступны"
        model.launchNotice = "Разрешите автозапуск"
        precondition(model.noticeDetails == "Данные недоступны\n\nРазрешите автозапуск",
                     "A data notice must not hide a concurrent login notice")
        for source in [ActivitySource.chatGPT, .work] {
            model.open(ActivityCard(threadID:UUID().uuidString,hostID:"chatgpt:account:user",source:source,
                                    title:source.label,project:"Test",summary:"Test",state:.unknown,updatedAt:.now))
            precondition(model.noticeDetails == "Данные недоступны\n\nРазрешите автозапуск",
                         "A hosted card must not attempt navigation or change notices")
        }
        model.open(ActivityCard(threadID:"invalid",title:"Test",project:"Test",summary:"Test",state:.unknown,updatedAt:.now))
        precondition(model.noticeDetails == "Данные недоступны\n\nРазрешите автозапуск\n\nссылка на чат недоступна",
                     "A navigation error must preserve both existing notices")
        precondition(model.launchEnabled, "Autostart must default to on")
        await model.configureLoginItem(enable:true)
        precondition(service.registrations == 1 && model.launchEnabled)
        await model.configureLoginItem(enable:true)
        precondition(service.registrations == 1, "Register must be idempotent")
        await model.configureLoginItem(enable:false)
        precondition(!model.launchEnabled && service.status == .notRegistered)
        precondition(!PanelModel(loginService:service,preferences:prefs).launchEnabled, "Off must survive restart")
        await model.configureLoginItem(enable:true)
        service.fail=true
        await model.configureLoginItem(enable:false)
        precondition(model.launchEnabled && model.launchNotice != nil && !model.launchChanging, "Failed removal must retain saved choice")
        service.fail=false; service.status = .requiresApproval
        model.updateLoginStatus()
        precondition(model.launchEnabled && model.launchNeedsApproval, "Pending approval must preserve user intent")
        service.status = .enabled; service.suspended=true
        let task=Task { @MainActor in await model.configureLoginItem(enable:false) }
        while service.continuation == nil { await Task.yield() }
        precondition(model.launchChanging)
        let count=service.registrations
        await model.configureLoginItem(enable:true)
        precondition(service.registrations == count, "Concurrent toggles must not race")
        service.continuation?.resume(); await task.value
        precondition(!model.launchEnabled && !model.launchChanging)
        precondition(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared), "Dismissing transient windows must not quit the panel")
        testHeaderDragAndZoom(model: model, width:150)
        testHeaderDragAndZoom(model: model, width:131)
        testHeaderDragAndZoom(model: model, width:124)
        testRunningCaptions()
        testPeriodPreferenceIsolation()
        try await testReadFailureAndRecovery()
        try await testLauncherRetries()
        testGroupMoveAtScrollLimit(model: model)
        print("Panel regressions passed: preferences and token visibility, login controls, window lifecycle, header drag and zoom, scroll limit, status transitions")
    }
}
