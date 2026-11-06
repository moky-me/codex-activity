import Darwin
import Foundation

/// The state database owns the chat total. A turn total is the difference
/// between cumulative counters at its projected rollout boundaries.
struct TokenUsageReader {
    struct Turn: Equatable {
        let id: String
        let start: Int64
        let end: Int64
        let isOpen: Bool

        fileprivate init(id: String, start: Int64, end: Int64, isOpen: Bool) {
            self.id = id
            self.start = start
            self.end = end
            self.isOpen = isOpen
        }

        init?(_ row: [String: DBValue]?) {
            guard let id = row?["turn_id"]?.string, let start = row?["rollout_byte_offset"]?.integer,
                  let status = row?["status"]?.string else { return nil }
            let isOpen = status == "inProgress"
            guard let end = row?[isOpen ? "projected_end" : "rollout_end_byte_offset"]?.integer,
                  start >= 0, end > start else { return nil }
            self.id = id
            self.start = start
            self.end = end
            self.isOpen = isOpen
        }
    }

    enum Boundary: Equatable {
        case indexed(Turn)
        case live(id: String, isOpen: Bool)
    }

    private struct Event: Decodable {
        private enum CodingKeys: String, CodingKey { case type, payload }

        struct Payload: Decodable {
            private enum CodingKeys: String, CodingKey { case type, turnId, info }

            struct Info: Decodable {
                struct Total: Decodable { let totalTokens: Int64 }
                let totalTokenUsage: Total
            }
            let type: String
            let turnId: String?
            let info: Info?

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                type = try fields.decode(String.self, forKey: .type)
                turnId = try fields.decodeIfPresent(String.self, forKey: .turnId)
                // A rate-limit update can explicitly carry null. A missing
                // or malformed counter field is a different case.
                info = type == "token_count" ? try fields.decode(Info?.self, forKey: .info) : nil
            }
        }
        let payload: Payload?

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let type = try fields.decode(String.self, forKey: .type)
            payload = type == "event_msg" ? try fields.decode(Payload.self, forKey: .payload) : nil
        }
    }

    private enum Counter { case value(Int64), missing, invalid }

    private struct CacheKey: Equatable {
        let file: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let changedAt: timespec
        let boundary: Boundary

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.file == rhs.file && lhs.device == rhs.device && lhs.inode == rhs.inode &&
                lhs.size == rhs.size && lhs.changedAt.tv_sec == rhs.changedAt.tv_sec &&
                lhs.changedAt.tv_nsec == rhs.changedAt.tv_nsec && lhs.boundary == rhs.boundary
        }
    }

    private static let scanLimit: Int64 = 256 * 1024
    private static let recentBoundaryLimit: Int64 = 2 * 1024 * 1024
    private static let extendedBoundaryLimit: Int64 = 16 * 1024 * 1024
    private static let eventLimit = 8 * 1024
    private static let tokenEvent = Data("\"token_count\"".utf8)
    private static let turnEvents = ["task_started", "task_complete", "turn_aborted"]
    private static let turnMarkers = turnEvents.map { Data(("\"" + $0 + "\"").utf8) }
    private let sessions: String
    private var cache: [String: (key: CacheKey, count: Int64?)] = [:]

    init(root: URL) {
        sessions = root.appendingPathComponent("sessions").resolvingSymlinksInPath().path
    }

    mutating func retain(threads: Set<String>) {
        cache = cache.filter { threads.contains($0.key) }
    }

    mutating func usage(threadID: String, chat: Int64?, path: String?, boundary: Boundary?) -> ActivityTokenUsage? {
        guard let chat, chat > 0 else { return nil }
        let turn = boundary.flatMap { readTurn(threadID: threadID, path: path, boundary: $0) }
        return ActivityTokenUsage(turn: turn.flatMap { $0 <= chat ? $0 : nil }, chat: chat)
    }

    private mutating func readTurn(threadID: String, path: String?, boundary: Boundary) -> Int64? {
        guard let path, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(sessions + "/"),
              url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { return nil }
        let nameMatches = url.lastPathComponent.lowercased().hasSuffix(threadID.lowercased() + ".jsonl")
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let key = CacheKey(file: url.path, device: info.st_dev, inode: info.st_ino,
                           size: info.st_size, changedAt: info.st_ctimespec, boundary: boundary)
        if let entry = cache[threadID], entry.key == key { return entry.count }
        // Some Codex journals carry the chat ID in the header only.
        guard nameMatches || (try? Self.headerMatches(file, threadID:threadID)) == true else { return nil }
        let count: Int64?
        do {
            let turn: Turn?
            switch boundary {
            case .indexed(let indexed):
                turn = indexed.end <= info.st_size ? indexed : nil
            case .live(let id, let isOpen):
                let recent = try Self.findLiveTurn(file, id:id, isOpen:isOpen, size:info.st_size,
                                                   limit:Self.recentBoundaryLimit)
                if recent == nil, !isOpen, info.st_size > Self.recentBoundaryLimit {
                    turn = try Self.findLiveTurn(file, id:id, isOpen:isOpen, size:info.st_size,
                                                 limit:Self.extendedBoundaryLimit)
                } else {
                    turn = recent
                }
            }
            count = try turn.flatMap { try Self.readCounters(file, boundary:$0) }
        }
        catch { return nil }
        cache[threadID] = (key, count)
        return count
    }

    private static func headerMatches(_ file: FileHandle, threadID: String) throws -> Bool {
        guard let line = try file.read(upToCount:Int(scanLimit))?.firstLine,
              let header = try JSONSerialization.jsonObject(with:line) as? [String: Any],
              header["type"] as? String == "session_meta",
              let payload = header["payload"] as? [String: Any] else { return false }
        return (payload["id"] as? String)?.lowercased() == threadID.lowercased()
    }

    private static func findLiveTurn(_ file: FileHandle, id: String, isOpen: Bool, size: Int64, limit: Int64) throws -> Turn? {
        let offset = max(0, size - limit)
        try file.seek(toOffset: UInt64(offset))
        let length = Int(size - offset)
        guard let bytes = try file.read(upToCount:length), bytes.count == length,
              let lastNewline = bytes.lastIndex(of:10) else { return nil }
        let complete = bytes[..<lastNewline]
        let lines = complete.split(separator:10).dropFirst(offset == 0 ? 0 : 1)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var finish: Int64?
        for line in lines.reversed() {
            guard turnMarkers.contains(where: { line.range(of:$0) != nil }) else { continue }
            guard let record = try? decoder.decode(Event.self, from:line) else { return nil }
            guard let event = record.payload, turnEvents.contains(event.type) else { continue }
            guard event.turnId == id else { return nil }
            if event.type == "task_started" {
                guard isOpen || finish != nil else { return nil }
                return Turn(id:id, start:offset + Int64(line.startIndex),
                            end:finish ?? offset + Int64(lastNewline) + 1, isOpen:finish == nil)
            }
            guard finish == nil else { return nil }
            finish = offset + Int64(line.endIndex) + 1
        }
        return nil
    }

    private static func readCounters(_ file: FileHandle, boundary: Turn) throws -> Int64? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func payload(_ line: Data) -> Event.Payload? {
            (try? decoder.decode(Event.self, from: line))?.payload
        }
        func counter(_ lines: ArraySlice<Data>, requireIntactSuffix: Bool = false) -> Counter {
            for line in lines.reversed() {
                let hasCounterMarker = line.range(of: tokenEvent) != nil
                guard requireIntactSuffix || hasCounterMarker else { continue }
                guard !hasCounterMarker || line.count <= eventLimit,
                      let record = try? decoder.decode(Event.self, from: line) else { return .invalid }
                guard let event = record.payload, event.type == "token_count",
                      let count = event.info?.totalTokenUsage.totalTokens else { continue }
                return count >= 0 ? .value(count) : .invalid
            }
            return .missing
        }
        func precedesFirstTurn(_ line: Data) -> Bool {
            guard let record = try? decoder.decode(Event.self, from: line) else { return false }
            guard let event = record.payload else { return true }
            return event.type != "task_started" && event.type != "task_complete" && event.type != "turn_aborted"
        }

        try file.seek(toOffset: UInt64(boundary.start))
        guard let start = try file.read(upToCount: eventLimit)?.firstLine,
              let marker = payload(start), marker.type == "task_started", marker.turnId == boundary.id else { return nil }
        let before = try tail(file, from: 0, to: boundary.start)
        let during = try tail(file, from: boundary.start, to: boundary.end)
        guard let before, let during else { return nil }
        if !boundary.isOpen {
            guard let last = during.last.flatMap(payload),
                  ["task_complete", "turn_aborted"].contains(last.type),
                  last.turnId == boundary.id else { return nil }
        }
        let baseline: Int64
        // A corrupt record after an older counter could have held a newer baseline.
        switch counter(before, requireIntactSuffix: true) {
        case .value(let count): baseline = count
        case .missing where boundary.start <= scanLimit && before.allSatisfy(precedesFirstTurn): baseline = 0
        default: return nil
        }
        guard case .value(let latest) = counter(during), latest >= baseline else { return nil }
        return latest - baseline
    }

    private static func tail(_ file: FileHandle, from start: Int64, to end: Int64) throws -> ArraySlice<Data>? {
        guard end > start else { return [] }
        let offset = max(start, end - scanLimit)
        try file.seek(toOffset: UInt64(offset))
        let length = Int(end - offset)
        guard let bytes = try file.read(upToCount: length), bytes.count == length, bytes.last == 10 else { return nil }
        return bytes.split(separator: 10).dropFirst(offset == start ? 0 : 1)
    }
}

private extension Data {
    var firstLine: Data? { firstIndex(of: 10).map { self[..<$0] } }
}
