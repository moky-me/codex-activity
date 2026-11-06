import Foundation

enum ChatGPTCatalog {
    private struct DesktopState: Decodable {
        struct Atoms: Decodable {
            struct Identity: Decodable {
                let accountId: String
                let userId: String
            }

            let identity: Identity?
            enum CodingKeys: String, CodingKey { case identity = "local-document-identity" }
        }

        let atoms: Atoms
        enum CodingKeys: String, CodingKey { case atoms = "electron-persisted-atom-state" }
    }

    static func currentHost(in root: URL) -> String? {
        // The desktop clears this identity at sign-out or on a principal change.
        // The catalog itself can retain rows from more than one account.
        guard let data = try? Data(contentsOf:root.appendingPathComponent(".codex-global-state.json")),
              let identity = try? JSONDecoder().decode(DesktopState.self,from:data).atoms.identity,
              !identity.accountId.isEmpty, !identity.userId.isEmpty,
              !identity.accountId.contains(":"), !identity.userId.contains(":") else { return nil }
        return "chatgpt:\(identity.accountId):\(identity.userId)"
    }

    static func cards(in catalog: SQLiteReader, hostID: String, now: Date, period: ActivityPeriod) throws -> [ActivityCard] {
        let rows = try catalog.query("""
            SELECT c.thread_id, c.display_title, c.project_id, c.source_recency_at,
                   c.conversation_origin, c.trial_conversation_type, c.chatgpt_async_status
            FROM local_thread_catalog c JOIN local_thread_catalog_hosts h ON h.host_id=c.host_id
            WHERE c.host_id=? AND h.host_kind='chatgpt' AND c.source_kind='chatgpt' AND c.missing_candidate=0
            """, [.text(hostID)])
        return rows.compactMap { row in
            guard let id = row["thread_id"]?.string, UUID(uuidString:id) != nil,
                  let seconds = row["source_recency_at"]?.number, seconds.isFinite, seconds > 0 else { return nil }
            let activity = Date(timeIntervalSince1970:seconds)
            guard ActivityPolicy.includes(updatedAt:activity,pending:false,now:now,period:period) else { return nil }

            let source: ActivitySource = row["conversation_origin"]?.string == "tpp" ||
                row["trial_conversation_type"]?.string == "work" ? .work : .chatGPT
            let status: ActivityState
            let summary: String
            switch row["chatgpt_async_status"]?.integer {
            case 3 where ActivityPolicy.includes(updatedAt:activity,pending:false,now:now,period:.day):
                // STREAMING. The catalog has no turn start. Do not promote old cached streams.
                status = .running
                summary = source == .work ? "Работает над задачей" : "Генерирует ответ"
            case 4: // UNREAD, a completed asynchronous response.
                status = .completed
                summary = "Ответ готов"
            default:
                status = .unknown
                summary = "Статус хода недоступен"
            }

            let title = row["display_title"]?.string?.trimmingCharacters(in:.whitespacesAndNewlines)
            let project = row["project_id"]?.string == nil ? "Без проекта" : "Проект"
            return ActivityCard(threadID:id,hostID:hostID,source:source,
                title:title.flatMap { $0.isEmpty || $0 == id ? nil : $0 } ?? "Без названия",
                project:project,summary:summary,state:status,updatedAt:activity)
        }
    }
}
