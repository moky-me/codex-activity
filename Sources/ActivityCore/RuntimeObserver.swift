import Foundation
import Darwin

public enum ExecutionStatus: String, Sendable { case active, idle }

public struct LocalExecution: Equatable, Sendable {
    public let status: ExecutionStatus
    fileprivate var activeFlags: [String] = []
    fileprivate var requests: [BlockingRequest?] = []
    fileprivate var snapshot: RemoteActivity?

    public init(status: ExecutionStatus) { self.status = status }

    func waits(for turnID: String) -> Bool {
        status == .active && (hasWaitingFlag(activeFlags)
            || requests.contains { $0?.applies(to:turnID) == true })
    }

    var currentActivity: RemoteActivity? {
        guard let snapshot, snapshot.isActive == (status == .active) else { return nil }
        return snapshot
    }
}

func hasWaitingFlag(_ flags: [String]) -> Bool {
    flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
}

enum BlockingRequest: Equatable, Sendable {
    case turn(String), thread

    init?(_ value: Any?) {
        guard let request = value as? [String: Any], request["completed"] as? Bool != true,
              let method = request["method"] as? String, Self.methods.contains(method),
              let params = request["params"] as? [String: Any],
              params["isBlocking"] as? Bool != false else { return nil }
        if let turnID = params["turnId"] as? String {
            self = .turn(turnID)
        } else if method == "mcpServer/elicitation/request" {
            self = .thread
        } else {
            return nil
        }
    }

    func applies(to turnID: String?) -> Bool {
        switch self {
        case .turn(let id): return id == turnID
        case .thread: return true
        }
    }

    private static let methods: Set<String> = [
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
        "item/permissions/requestApproval", "item/tool/requestUserInput",
        "item/tool/requestOptionPicker", "mcpServer/elicitation/request"
    ]
}

public struct RuntimeThreadKey: Hashable, Sendable {
    public let hostID: String
    public let threadID: String

    public init(hostID: String, threadID: String) {
        self.hostID = hostID
        self.threadID = threadID
    }
}

public protocol ExecutionObserving: AnyObject {
    var revision: UInt64 { get }
    func observe(threadIDs: Set<String>) -> [String: LocalExecution]
    func observeRemote(threads: Set<RuntimeThreadKey>) -> [RuntimeThreadKey: RemoteActivity]
}

public extension ExecutionObserving {
    func observeRemote(threads: Set<RuntimeThreadKey>) -> [RuntimeThreadKey: RemoteActivity] { [:] }
}

/// Keeps only runtime metadata. Unknown protocol and revision gaps discard the affected state.
public struct RuntimeProjection {
    private struct Entry {
        let owner: String
        var revision: Int
        var status: ExecutionStatus?
        var activity: RemoteActivity?
        var activeFlags: [String] = []
        var requests: [BlockingRequest?] = []
    }
    private var entries: [RuntimeThreadKey: Entry] = [:]

    public init() {}
    public var statuses: [RuntimeThreadKey: ExecutionStatus] { entries.compactMapValues(\.status) }
    public var remoteActivities: [RuntimeThreadKey: RemoteActivity] {
        entries.filter { $0.key.hostID != "local" }.compactMapValues(\.activity)
    }
    public var localExecutions: [String: LocalExecution] {
        var result: [String: LocalExecution] = [:]
        for (key, entry) in entries where key.hostID == "local" {
            guard let status = entry.status else { continue }
            var execution = LocalExecution(status:status)
            execution.activeFlags = entry.activeFlags
            execution.requests = entry.requests
            execution.snapshot = entry.activity
            result[key.threadID] = execution
        }
        return result
    }
    public mutating func retain(_ keys: Set<RuntimeThreadKey>) { entries = entries.filter { keys.contains($0.key) } }
    public mutating func reset() { entries.removeAll() }
    fileprivate mutating func remove(_ key: RuntimeThreadKey) { entries[key] = nil }

    public mutating func consume(_ message: [String: Any], watching: Set<RuntimeThreadKey>,
                                 onSnapshot: (RuntimeThreadKey) -> Void = { _ in }) -> RuntimeThreadKey? {
        guard message["type"] as? String == "broadcast" else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        if message["method"] as? String == "client-status-changed",
           params["status"] as? String == "disconnected", let owner = params["clientId"] as? String {
            entries = entries.filter { $0.value.owner != owner }
            return nil
        }
        guard message["method"] as? String == "thread-stream-state-changed",
              let host = params["hostId"] as? String, let id = params["conversationId"] as? String,
              let owner = message["sourceClientId"] as? String,
              let change = params["change"] as? [String: Any] else { return nil }
        let key = RuntimeThreadKey(hostID: host, threadID: id)
        guard watching.contains(key) else { return nil }
        guard message["version"] as? Int == 11, let revision = change["revision"] as? Int else {
            entries[key] = nil
            return nil
        }
        if change["type"] as? String == "snapshot" {
            guard let state = change["conversationState"] as? [String: Any],
                  (state["hostId"] as? String).map({ $0 == host }) ?? true,
                  (state["id"] as? String).map({ $0 == id }) ?? true else {
                entries[key] = nil
                return nil
            }
            if let entry = entries[key], entry.owner == owner, entry.revision > revision { return nil }
            let runtime = state["threadRuntimeStatus"] as? [String: Any]
            let status = (runtime?["type"] as? String).flatMap(ExecutionStatus.init(rawValue:))
            var entry = Entry(owner:owner,revision:revision,status:status)
            entry.activity = RemoteActivity(snapshot:state,execution:status)
            if host == "local" {
                entry.activeFlags = runtime?["activeFlags"] as? [String] ?? []
                entry.requests = (state["requests"] as? [Any] ?? []).map(BlockingRequest.init)
            }
            entries[key] = entry
            onSnapshot(key)
            return nil
        }
        guard change["type"] as? String == "patches", var entry = entries[key], entry.owner == owner,
              entry.revision == change["baseRevision"] as? Int, revision > entry.revision,
              let patches = change["patches"] as? [[String: Any]] else {
            entries[key] = nil
            return key
        }
        var needsSnapshot = false
        for patch in patches {
            guard let path = patch["path"] as? [Any], let root = path.first as? String else {
                entries[key] = nil
                return key
            }
            if host != "local", root == "latestTokenUsageInfo" {
                entry.activity?.applyTokenUsagePatch(patch, path:path)
                continue
            }
            needsSnapshot = needsSnapshot || Self.affectsActivitySnapshot(root:root,path:path,patch:patch)
            guard host == "local" else { continue }
            if root == "threadRuntimeStatus" {
                if path.count == 1 {
                    let runtime = patch["value"] as? [String: Any]
                    entry.status = (runtime?["type"] as? String).flatMap(ExecutionStatus.init(rawValue:))
                    entry.activeFlags = runtime?["activeFlags"] as? [String] ?? []
                } else if path.count == 2, path[1] as? String == "type" {
                    entry.status = (patch["value"] as? String).flatMap(ExecutionStatus.init(rawValue:))
                    if entry.status != .active { entry.activeFlags = [] }
                } else if path[1] as? String == "activeFlags" {
                    if path.count == 2 {
                        entry.activeFlags = patch["value"] as? [String] ?? []
                    } else if !Self.applyArrayPatch(patch,path:path,indexAt:2,to:&entry.activeFlags,
                                                    decode:{ $0 as? String ?? "" }) {
                        entry.activeFlags = []
                        needsSnapshot = true
                    }
                }
            } else if root == "requests" {
                if path.count == 1 {
                    entry.requests = (patch["value"] as? [Any] ?? []).map(BlockingRequest.init)
                } else if !Self.applyArrayPatch(patch,path:path,indexAt:1,to:&entry.requests,
                                                decode:BlockingRequest.init) {
                    // A field-level change can alter whether the request blocks.
                    if let index = path[1] as? Int, entry.requests.indices.contains(index) {
                        entry.requests[index] = nil
                    } else {
                        entry.requests = []
                    }
                    needsSnapshot = true
                }
            }
        }
        entry.revision = revision
        entries[key] = entry
        return needsSnapshot ? key : nil
    }

    private static func applyArrayPatch<Element>(_ patch: [String: Any], path: [Any], indexAt: Int,
                                                 to values: inout [Element], decode: (Any?) -> Element) -> Bool {
        guard path.count == indexAt + 1, let index = path[indexAt] as? Int else { return false }
        switch patch["op"] as? String {
        case "add" where (0...values.count).contains(index):
            values.insert(decode(patch["value"]),at:index)
        case "replace" where values.indices.contains(index):
            values[index] = decode(patch["value"])
        case "remove" where values.indices.contains(index):
            values.remove(at:index)
        default:
            return false
        }
        return true
    }

    private static func affectsActivitySnapshot(root: String, path: [Any], patch: [String: Any]) -> Bool {
        if root == "threadRuntimeStatus" || root == "requests" { return true }
        let fieldIndex: Int
        switch root {
        case "turns": fieldIndex = 2
        case "turnHistory":
            // History replacement, changes to ordering, and new/removed entities.
            guard path.count > 4 else { return true }
            if path[2] as? String == "islands" { return true }
            guard path[2] as? String == "entitiesByKey" else { return false }
            fieldIndex = 4
        default: return false
        }
        guard path.count > fieldIndex else { return true }
        switch path[fieldIndex] as? String {
        case "status", "turnStartedAtMs", "durationMs": return true
        case "items":
            if path.count == fieldIndex + 1 { return true }
            if path.count == fieldIndex + 2 {
                if patch["op"] as? String == "remove" { return true }
                let item = patch["value"] as? [String: Any]
                let type = item?["type"] as? String
                return type == "userMessage" || type == "steeringUserMessage"
                    || (item?["questions"] as? [[String: Any]])?.isEmpty == false
            }
            let field = path[fieldIndex + 2] as? String
            return field == "questions" || (field == "status" && patch["value"] as? String == "accepted")
        default: return false
        }
    }
}

/// Native, local IPC observer. Subscribes to existing streams; cannot start/resume turns.
public final class RuntimeObserver: ExecutionObserving {
    private let worker: Worker
    public init(socketPath:String) { worker=Worker(path:socketPath) }
    deinit { worker.lock.lock(); worker.stopped=true; worker.lock.unlock() }
    public var revision:UInt64 { worker.lock.lock(); defer { worker.lock.unlock() }; return worker.revision }
    public func observe(threadIDs:Set<String>) -> [String:LocalExecution] {
        worker.lock.lock(); defer { worker.lock.unlock() }
        worker.local = Set(threadIDs.map { RuntimeThreadKey(hostID: "local", threadID: $0) })
        startWorkerIfNeeded()
        return worker.executions.filter { threadIDs.contains($0.key) }
    }

    public func observeRemote(threads: Set<RuntimeThreadKey>) -> [RuntimeThreadKey: RemoteActivity] {
        worker.lock.lock(); defer { worker.lock.unlock() }
        worker.remote = threads
        startWorkerIfNeeded()
        return worker.activities.filter { threads.contains($0.key) }
    }

    private func startWorkerIfNeeded() {
        if (!worker.local.isEmpty || !worker.remote.isEmpty) && !worker.started {
            worker.started=true
            let worker=worker
            DispatchQueue(label:"io.github.moky-me.CodexActivity.runtime",qos:.utility).async { worker.run() }
        }
    }
    private final class Worker {
        let path:String; let lock=NSLock()
        var local = Set<RuntimeThreadKey>()
        var remote = Set<RuntimeThreadKey>()
        var executions: [String: LocalExecution] = [:]
        var activities: [RuntimeThreadKey: RemoteActivity] = [:]
        var revision: UInt64 = 0
        var stopped=false, started=false
        init(path:String) { self.path=path }
        func publish(_ projection:RuntimeProjection) {
            lock.lock(); defer { lock.unlock() }
            let next = projection.localExecutions.filter {
                local.contains(RuntimeThreadKey(hostID:"local",threadID:$0.key))
            }
            let nextRemote = projection.remoteActivities.filter { remote.contains($0.key) }
            if next != executions || nextRemote != activities {
                executions = next
                activities = nextRemote
                revision &+= 1
            }
        }
        func run() {
            while true {
                lock.lock(); let stop=stopped; lock.unlock(); if stop { return }
                connectAndRead()
                publish(RuntimeProjection())
                Thread.sleep(forTimeInterval:1)
            }
        }
        func connectAndRead() {
            var info=stat()
            guard lstat(path,&info)==0, info.st_uid==getuid(), info.st_mode & S_IFMT == S_IFSOCK else { return }
            let fd=socket(AF_UNIX,SOCK_STREAM,0); guard fd>=0 else { return }; defer { close(fd) }
            var noSignal:Int32=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout.size(ofValue:noSignal)))
            _=fcntl(fd,F_SETFL,O_NONBLOCK)
            var address=sockaddr_un(); address.sun_family=sa_family_t(AF_UNIX)
            let bytes=Array(path.utf8)+[0]
            guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else { return }
            withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes) }
            address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
            let connected=withUnsafePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard connected==0 else { return }
            func send(_ message:[String:Any]) -> Bool {
                guard let data=try? JSONSerialization.data(withJSONObject:message) else { return false }
                var count=UInt32(data.count).littleEndian
                var frame=withUnsafeBytes(of:&count) { Data($0) }; frame.append(data)
                return frame.withUnsafeBytes { raw in
                    var offset=0
                    while offset<raw.count {
                        let n=Darwin.send(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,0)
                        if n>0 { offset+=n; continue }
                        if errno==EINTR { continue }
                        return false
                    }
                    return true
                }
            }
            let requestID=UUID().uuidString
            guard send(["type":"request","requestId":requestID,"method":"initialize","version":0,"params":["clientType":"codex-activity"]]) else { return }
            var client:String?, subscribed=Set<RuntimeThreadKey>(), projection=RuntimeProjection(), buffer=Data(), offset=0
            var pendingRefresh = Set<RuntimeThreadKey>()
            var lastRefresh: [RuntimeThreadKey: TimeInterval] = [:]
            var awaitingSnapshot: [RuntimeThreadKey: (startedAt: TimeInterval, isRetry: Bool)] = [:]
            let initializedBy=Date().addingTimeInterval(3)
            func follow(_ key: RuntimeThreadKey, _ enabled: Bool) -> Bool {
                send(["type":"broadcast","method":"thread-stream-following-changed","version":1,"sourceClientId":client ?? "","params":["hostId":key.hostID,"conversationId":key.threadID,"following":enabled]])
            }
            var chunk=[UInt8](repeating:0,count:65536)
            while true {
                lock.lock(); let stop=stopped, desired=local.union(remote); lock.unlock(); if stop { return }
                if client != nil {
                    let time = ProcessInfo.processInfo.systemUptime
                    if desired != subscribed { projection.retain(desired.intersection(subscribed)); publish(projection) }
                    for id in desired.subtracting(subscribed) {
                        guard follow(id,true) else { return }
                        awaitingSnapshot[id] = (time, false)
                        lastRefresh[id] = time
                    }
                    for id in subscribed.subtracting(desired) { guard follow(id,false) else { return } }
                    subscribed=desired
                    pendingRefresh.formIntersection(desired)
                    lastRefresh = lastRefresh.filter { desired.contains($0.key) }
                    awaitingSnapshot = awaitingSnapshot.filter { desired.contains($0.key) }
                    // Fetch a coalesced fresh snapshot instead of storing transcript patches.
                    let due = pendingRefresh.filter {
                        awaitingSnapshot[$0] == nil && time - (lastRefresh[$0] ?? -.infinity) >= 1
                    }
                    for key in due {
                        guard follow(key, true) else { return }
                        lastRefresh[key] = time
                        awaitingSnapshot[key] = (time, false)
                    }
                    pendingRefresh.subtract(due)
                    let expired = awaitingSnapshot.filter { time - $0.value.startedAt >= 5 }
                    for (key, request) in expired {
                        projection.remove(key)
                        pendingRefresh.remove(key)
                        if request.isRetry {
                            awaitingSnapshot[key] = nil
                        } else {
                            guard follow(key,true) else { return }
                            awaitingSnapshot[key] = (time, true)
                            lastRefresh[key] = time
                        }
                    }
                    if !expired.isEmpty { publish(projection) }
                } else if Date()>initializedBy { return }
                var pollFD=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                let ready=poll(&pollFD,1,250)
                if ready<0 { if errno==EINTR { continue }; return }
                if ready==0 { continue }
                if pollFD.revents & Int16(POLLERR|POLLHUP|POLLNVAL) != 0 { return }
                let n=recv(fd,&chunk,chunk.count,0)
                if n<=0 { if n<0 && (errno==EAGAIN || errno==EINTR) { continue }; return }
                buffer.append(contentsOf:chunk.prefix(n))
                while buffer.count-offset>=4 {
                    let size=Int(buffer.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self)) })
                    guard size>0 && size<=64*1024*1024 else { return }
                    if buffer.count-offset<4+size { break }
                    let payload=buffer.subdata(in:offset+4..<offset+4+size); offset+=4+size
                    let handled=autoreleasepool { () -> Bool in
                    guard let message=(try? JSONSerialization.jsonObject(with:payload)) as? [String:Any] else { return false }
                    if message["type"] as? String == "response", message["requestId"] as? String == requestID {
                        client=(message["result"] as? [String:Any])?["clientId"] as? String
                        if client==nil { return false }
                    } else if message["type"] as? String == "client-discovery-request", let id=message["requestId"] as? String {
                        guard send(["type":"client-discovery-response","requestId":id,"response":["canHandle":false]]) else { return false }
                    } else if message["type"] as? String == "broadcast",
                              message["method"] as? String == "ipc-connection-reset" {
                        return false
                    } else {
                        let resync = projection.consume(message, watching: desired) { key in
                            awaitingSnapshot[key] = nil
                            pendingRefresh.remove(key)
                        }
                        if let resync { pendingRefresh.insert(resync) }
                        publish(projection)
                    }
                        return true
                    }
                    if !handled { return }
                }
                if offset>0 { buffer.removeSubrange(0..<offset); offset=0 }
            }
        }
    }
}
