import Foundation

public struct QuestionTracker: Equatable, Sendable {
    private struct Reply: Decodable {
        let questionItemId: String
        let question: String
        let answer: String
    }

    private enum Progress: Int, Sendable { case waiting, followedUp, resumed }

    private struct Question: Equatable, Sendable {
        let title: String
        let askedAt: Date?
        var progress: Progress
    }

    private var questions: [String:Question] = [:]
    private var answered: Set<String> = []
    public init() {}
    private var waiting: [String:Question] { questions.filter { $0.value.progress != .resumed } }
    var awaitsContinuation: Bool { questions.values.contains { $0.progress == .followedUp } }
    public var pendingCount:Int { waiting.count }
    public var firstTitle:String? { waiting.sorted { $0.key < $1.key }.first?.value.title }
    public var oldestQuestionAt:Date? { waiting.values.compactMap(\.askedAt).min() }
    public mutating func resolve(callID:String,questionIndex:Int) {
        let key="\(callID):\(questionIndex)"; answered.insert(key); questions.removeValue(forKey:key)
    }

    mutating func merge(_ live: Self) {
        answered.formUnion(live.answered)
        questions.merge(live.questions) { indexed, current in
            Question(title:current.title,askedAt:indexed.askedAt ?? current.askedAt,
                     progress:indexed.progress.rawValue >= current.progress.rawValue ? indexed.progress : current.progress)
        }
        for id in answered { questions.removeValue(forKey:id) }
    }

    public mutating func consume(item:[String:Any], at date:Date? = nil) {
        let type = item["type"] as? String
        if type == "agentMessage" {
            if Self.isContinuationCommentary(item) {
                // A later commentary confirms that work continued after the user followed up.
                for key in questions.keys where questions[key]?.progress == .followedUp {
                    questions[key]?.progress = .resumed
                }
            }
            if let id=item["id"] as? String, let list=item["questions"] as? [[String:Any]] {
                for (index,question) in list.enumerated() {
                    let key="\(id):\(index)"
                    if !answered.contains(key) {
                        questions[key] = Question(title:(question["title"] as? String) ?? "нужен ваш ответ",
                                                  askedAt:questions[key]?.askedAt ?? date,
                                                  progress:questions[key]?.progress ?? .waiting)
                    }
                }
            }
        }
        let content:[[String:Any]]
        if type == "userMessage", let blocks=item["content"] as? [[String:Any]] { content=blocks }
        else if type == "steeringUserMessage",
                item["status"] as? String == "accepted",
                let blocks=item["input"] as? [[String:Any]] { content=blocks }
        else { return }
        let text = content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator:"\n")
        let open = "<send_user_message_question_reply>"
        let close = "</send_user_message_question_reply>"
        let payload = Self.replyBody(text, openingTag:open)
        guard payload.hasPrefix(open), payload.hasSuffix(close) else {
            // Only an accepted regular message can precede a resumption. A quoted
            // widget reply is still neither a resolution nor a follow-up signal.
            if type == "userMessage", !payload.isEmpty, !payload.contains(open) {
                for key in questions.keys where questions[key]?.progress == .waiting {
                    questions[key]?.progress = .followedUp
                }
            }
            return
        }
        let bytes = Data(payload.dropFirst(open.count).dropLast(close.count).utf8)
        let decoder = JSONDecoder()
        let replies = (try? decoder.decode([Reply].self,from:bytes))
            ?? (try? decoder.decode(Reply.self,from:bytes)).map { [$0] } ?? []
        for reply in replies {
            guard let parts = (try? JSONSerialization.jsonObject(with:Data(reply.questionItemId.utf8))) as? [Any],
                  parts.count == 3, parts[0] as? String == "request_user_input_async",
                  let call = parts[1] as? String, let index = parts[2] as? Int else { continue }
            resolve(callID:call,questionIndex:index)
        }
    }

    static func isContinuationCommentary(_ item: [String: Any]) -> Bool {
        item["type"] as? String == "agentMessage" && item["phase"] as? String == "commentary"
            && hasText(item["text"])
    }

    static func hasText(_ value: Any?) -> Bool {
        (value as? String)?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false
    }

    private static func replyBody(_ text: String, openingTag: String) -> String {
        // The heading alone is also ordinary Markdown. Only unwrap a known attachment envelope.
        var message = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if message.hasPrefix("# Files mentioned by the user:\n") || message.hasPrefix("# Files pasted by the user:\n"),
           let delimiter = message.range(of:"\n## My request:\n"),
           message[..<delimiter.lowerBound].range(of:#"(?m)^(?:##|- )\s*.+: /[^\r\n]+$"#,options:.regularExpression) != nil {
            message = message[delimiter.upperBound...].trimmingCharacters(in:.whitespacesAndNewlines)
        }
        if message.hasPrefix(openingTag) { return message }
        if let sender = message.range(of:#"^\[from: [^\]\r\n]+\](?:\r?\n|$)"#,options:.regularExpression) {
            return message[sender.upperBound...].trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let wrapper = #"^<codex_multi_user_message>\s*<account_user_id>[\s\S]*?</account_user_id>\s*<name>[\s\S]*?</name>\s*<email>[\s\S]*?</email>\s*<profile_picture_url>[\s\S]*?</profile_picture_url>\s*<body>([\s\S]*?)</body>\s*</codex_multi_user_message>$"#
        guard let regex = try? NSRegularExpression(pattern:wrapper),
              let match = regex.firstMatch(in:message,range:NSRange(message.startIndex...,in:message)),
              let body = Range(match.range(at:1),in:message) else { return message }
        return [("&lt;","<"),("&gt;",">"),("&quot;","\""),("&apos;","'"),("&amp;","&")]
            .reduce(String(message[body])) { $0.replacingOccurrences(of:$1.0,with:$1.1) }
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
