import Foundation

/// 「发之前看看」的结果：用户要发的英文草稿，对方读起来是什么感觉，有没有更地道的写法。
public struct DraftReview: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var draft: String
    /// 英语母语的对方读到会是什么感觉，一句中文。
    public var landsAs: String?
    /// 规范值（Vocabulary.verdicts），例如「太生硬」。
    public var verdict: String
    /// 具体问题，一句中文。
    public var issues: String?
    /// 更地道的英文写法。
    public var rewrite: String?
    /// 改写后的中文意思。
    public var rewriteGloss: String?
    public var engine: String
    public var latencyMs: Double

    public init(draft: String, landsAs: String?, verdict: String, issues: String?, rewrite: String?, rewriteGloss: String?,
                engine: String, latencyMs: Double) {
        self.draft = draft
        self.landsAs = landsAs
        self.verdict = verdict
        self.issues = issues
        self.rewrite = rewrite
        self.rewriteGloss = rewriteGloss
        self.engine = engine
        self.latencyMs = latencyMs
    }

    /// 改写和草稿只差空白、标点时，界面上不再重复一遍。
    public var rewriteDiffers: Bool {
        guard let rewrite else { return false }
        let squash = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return squash(rewrite) != squash(draft)
    }
}

/// 用生成式大模型检查用户要发的英文回复。提示词在 presets/draft.llm.zh.json。
public struct DraftChecker: Sendable {
    public var backend: ChatBackend
    public var prompt: LLMPrompt
    public var relationship: String?

    public init(backend: ChatBackend, prompt: LLMPrompt, relationship: String? = nil) {
        self.backend = backend
        self.prompt = prompt
        self.relationship = relationship
    }

    public static let answerKeys = ["lands_as", "verdict", "issues", "rewrite", "rewrite_zh"]

    /// 聊天记录在前（让模型知道在回什么），最后是草稿。格式和示例里的完全一样。
    public static func render(context: [ChatMessage], draft: String, relationship: String?) -> String {
        let relation = Vocabulary.canonical(relationship, in: Vocabulary.relationships) ?? relationship
        var text = ""
        if let relation, !relation.isEmpty, relation != "不确定" {
            text += "Relationship: \(Vocabulary.english(relation, in: Vocabulary.relationships) ?? relation)\n"
        }
        text += "Chat log (oldest first; \"Me\" is the user, \"Them\" is the other person):\n"
        text += context.map { ChatState.line($0, language: .en) }.joined(separator: "\n")
        text += "\n\nMy draft reply:\n" + draft
        return text
    }

    func turns(context: [ChatMessage], draft: String) throws -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for example in prompt.examples {
            turns.append(ChatTurn(role: "user", content: example.chat))
            turns.append(ChatTurn(role: "assistant", content: try Self.encode(example.answer)))
        }
        turns.append(ChatTurn(role: "user", content: Self.render(context: context, draft: draft, relationship: relationship)))
        return turns
    }

    static func encode(_ answer: [String: JSONValue]) throws -> String {
        let keys = answerKeys.filter { answer[$0] != nil }
        let fields = try keys.map { key -> String in
            "\"\(key)\": " + (String(data: try JSONEncoder().encode(answer[key]!), encoding: .utf8) ?? "null")
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    public func review(draft: String, context: [ChatMessage]) async throws -> DraftReview {
        let start = Date()
        let content = try await backend.complete(system: prompt.system, turns: turns(context: context, draft: draft), schema: prompt.schema)
        return try Self.review(from: content, draft: draft, engine: backend.name, latencyMs: Date().timeIntervalSince(start) * 1000)
    }

    public static func review(from content: String, draft: String, engine: String, latencyMs: Double) throws -> DraftReview {
        guard let json = LLMAnalyzer.parseObject(content) else { throw AnalyzerError.badResponse(String(content.prefix(200))) }
        let verdict = json["verdict"] as? String
        return DraftReview(
            draft: draft,
            landsAs: LLMAnalyzer.nonEmpty(json["lands_as"]),
            verdict: Vocabulary.canonical(verdict, in: Vocabulary.verdicts) ?? verdict ?? "未知",
            issues: LLMAnalyzer.nonEmpty(json["issues"]),
            rewrite: LLMAnalyzer.nonEmpty(json["rewrite"]),
            rewriteGloss: LLMAnalyzer.nonEmpty(json["rewrite_zh"]),
            engine: engine, latencyMs: latencyMs)
    }
}
