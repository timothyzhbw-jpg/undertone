import Foundation

/// 给生成式模型的提示词和示例，从 presets/emotion.llm.zh.json 读取，方便不改代码就调整。
public struct LLMPrompt: Codable, Sendable {
    public struct Example: Codable, Sendable {
        public var chat: String
        public var answer: [String: JSONValue]
    }

    public var system: String
    /// 聊天里出现表情、表情包、语音这类方括号内容时才附上的说明。
    /// 不放进 system：实测放进去以后，纯文字消息的判断也变了（「真给我丢人」的操控 4 次全漏）。
    public var mediaNote: String?
    public var examples: [Example]
    /// 提示词的语言，决定聊天记录用中文还是英文框架。没写时是中文。
    public var language: AppLanguage?
    /// 同目录下 JSON Schema 的文件名；没写时用 emotion.schema.json。
    public var schemaFile: String?
    /// 本地模型需要的上下文长度；没写时用 Ollama 后端的默认值。
    public var contextLength: Int?

    enum CodingKeys: String, CodingKey {
        case system, examples, schema, language
        case mediaNote = "media_note"
        case schemaFile = "schema_file"
        case contextLength = "context_length"
    }
    /// 输出格式的 JSON Schema 原文（同目录的 emotion.schema.json），云端模型用它做结构化输出。
    public var schema: String?

    public init(system: String, mediaNote: String? = nil, examples: [Example], schema: String? = nil, language: AppLanguage? = nil) {
        self.system = system
        self.mediaNote = mediaNote
        self.examples = examples
        self.schema = schema
        self.language = language
    }

    public static func load(from url: URL) throws -> LLMPrompt {
        var prompt = try JSONDecoder().decode(LLMPrompt.self, from: Data(contentsOf: url))
        let schemaURL = url.deletingLastPathComponent().appending(path: prompt.schemaFile ?? "emotion.schema.json")
        prompt.schema = try? String(contentsOf: schemaURL, encoding: .utf8)
        return prompt
    }
}

/// 用生成式大模型读潜台词、给回复建议。后端可以是本地 Ollama、OpenAI 兼容服务或 Claude。
public struct LLMAnalyzer: EmotionAnalyzer {
    public var backend: ChatBackend
    public var prompt: LLMPrompt
    public var relationship: String?
    public var memory: String?
    public var name: String { backend.name }

    public init(backend: ChatBackend, prompt: LLMPrompt, relationship: String? = nil, memory: String? = nil) {
        self.backend = backend
        self.prompt = prompt
        self.relationship = relationship
        self.memory = memory
    }

    /// few-shot 示例在前，当前对话在最后。
    func turns(context: [ChatMessage], latest: ChatMessage) throws -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for example in prompt.examples {
            turns.append(ChatTurn(role: "user", content: example.chat))
            turns.append(ChatTurn(role: "assistant", content: try Self.encodeInOrder(example.answer)))
        }
        var content = ChatState.render(context: context, latest: latest, relationship: relationship, memory: memory,
                                       language: prompt.language ?? .zh)
        if let note = prompt.mediaNote, !note.isEmpty, (context + [latest]).contains(where: { Self.hasMedia($0.text) }) {
            content += "\n\n" + note
        }
        turns.append(ChatTurn(role: "user", content: content))
        return turns
    }

    /// 「[表情：捂脸]」「[语音 5秒]」「[图片]」，以及手动粘贴时微信的「[捂脸]」这类表情代码。
    static func hasMedia(_ text: String) -> Bool {
        text.range(of: #"\[[^\[\]\s]{1,40}\]"#, options: .regularExpression) != nil
    }

    /// 评测时（Undertone --eval）把解析不了的原始输出整段写到标准错误，方便看模型到底输出了什么。应用里不开。
    nonisolated(unsafe) public static var dumpUnparsable = false

    public func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
        let start = Date()
        let content = try await backend.complete(system: prompt.system, turns: turns(context: context, latest: latest),
                                                 schema: prompt.schema)
        let latency = Date().timeIntervalSince(start) * 1000
        do {
            return try Self.report(from: content, message: latest, engine: name, latencyMs: latency)
        } catch {
            if Self.dumpUnparsable { FileHandle.standardError.write(Data("----- unparsable output -----\n\(content)\n-----\n".utf8)) }
            throw error
        }
    }

    /// 示例答案按提示词里的顺序输出：先字面、再真实想法、最后回复。字典本身是无序的。
    static let flagKeys = ["angry_at_me", "perfunctory", "needs_comfort", "testing", "cold_distance",
                           "conflict", "manipulation", "self_harm", "asks_money"]
    /// 情绪视角的输出字段。
    public static let emotionKeys = ["literal", "consistency", "real_meaning", "emotion", "intensity", "target"]
        + flagKeys + ["best_response", "suggested_reply", "memory_note"]
    /// 跨文化视角的输出字段：先讲说话习惯（why）、说真实意思，最后才归类（reading）。
    /// 第一轮评测里先归类时，模型常把解释成「不会采购了」的话标成「字面意思」。
    public static let subtextKeys = ["literal", "why", "real_meaning", "reading", "confidence", "emotion", "intensity", "target"]
        + flagKeys + ["best_response", "suggested_reply", "reply_zh", "memory_note"]

    static func encodeInOrder(_ answer: [String: JSONValue]) throws -> String {
        let order = answer["reading"] != nil ? subtextKeys : emotionKeys
        let keys = order.filter { answer[$0] != nil } + answer.keys.filter { !order.contains($0) }.sorted()
        let fields = try keys.map { key -> String in
            let value = try String(data: JSONEncoder().encode(answer[key]!), encoding: .utf8) ?? "null"
            return "\"\(key)\": \(value)"
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// 取出模型输出里的 JSON 对象。小模型偶尔用中文引号「“ ”」当字符串的边界，解析失败时修一次再试。
    static func parseObject(_ content: String) -> [String: Any]? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else { return nil }
        let raw = String(content[start...end])
        for candidate in [raw, repairQuotes(raw), escapeInnerQuotes(repairQuotes(raw))] {
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        }
        return nil
    }

    /// 字符串里没转义的英文引号（「使用"Let me check"是…」）：模型解释英文说法时常这样写，整段 JSON 就解析不了。
    /// 在字符串里遇到引号时，只有后面紧跟 JSON 结构（`}` `]` `:`，或者逗号后面是下一个键）才当作结束，否则转义成 \"。
    static func escapeInnerQuotes(_ json: String) -> String {
        let chars = Array(json)
        var out = ""
        var inString = false
        var i = 0
        func nextNonSpace(_ from: Int) -> Int? {
            var j = from
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j < chars.count ? j : nil
        }
        while i < chars.count {
            let c = chars[i]
            if inString, c == "\\", i + 1 < chars.count {
                out.append(c); out.append(chars[i + 1]); i += 2; continue
            }
            if c == "\"" {
                if !inString {
                    inString = true
                } else {
                    var closes = true
                    if let j = nextNonSpace(i + 1) {
                        switch chars[j] {
                        case "}", "]", ":": closes = true
                        case ",": closes = nextNonSpace(j + 1).map { ["\"", "}", "]"].contains(chars[$0]) } ?? true
                        default: closes = false
                        }
                    }
                    if closes { inString = false } else { out.append("\\") }
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// 只在原文解析失败时才用：中文弯引号当成了 JSON 引号；值以英文引文开头或结尾时，
    /// 小模型会把开头或结尾的引号写成 \"（"lands_as": \"look\" は…。", 或 …正しくありません。\", "rewrite": …）。
    static func repairQuotes(_ json: String) -> String {
        json.replacingOccurrences(of: #"([:\[,{]\s*)[“”]"#, with: "$1\"", options: .regularExpression)
            .replacingOccurrences(of: #"[“”](\s*[,}\]:])"#, with: "\"$1", options: .regularExpression)
            .replacingOccurrences(of: #"("\s*:\s*)\\""#, with: "$1\"\\\\\"", options: .regularExpression)
            .replacingOccurrences(of: #"\\"(\s*,\s*"[A-Za-z_]+"\s*:|\s*\}\s*$)"#, with: "\"$1", options: .regularExpression)
    }

    /// 解析模型输出的 JSON，对类型宽容（"true" / 1 / 0.8 都能当布尔用）。
    public static func report(from content: String, message: ChatMessage, engine: String, latencyMs: Double) throws -> EmotionReport {
        guard let json = parseObject(content) else { throw AnalyzerError.badResponse(String(content.prefix(200))) }

        var flags: [String: Double] = [:]
        for flag in EmotionFlag.allCases {
            flags[flag.rawValue] = probability(json[flag.rawValue])
        }
        let consistency = canonicalConsistency(json["consistency"] as? String)
        let reading = json["reading"] as? String
        // 小模型偶尔把情绪词（「冷淡」）填进话外音类型：认不出就不要这个标签，解释照常显示
        let canonicalReading = Vocabulary.canonical(reading, in: Vocabulary.readings)
        if consistency == "反话" || canonicalReading == "反话" { flags[EmotionFlag.sarcasm.rawValue] = 1 }
        // 英文提示词让模型输出英文标签，这里统一换回中文规范值；认不出的原样保留。
        let emotion = json["emotion"] as? String
        let response = json["best_response"] as? String
        let target = json["target"] as? String
        return EmotionReport(
            message: message,
            emotion: Vocabulary.canonical(emotion, in: Vocabulary.emotions) ?? emotion ?? "未知",
            intensity: min(3, max(0, number(json["intensity"]) ?? 0)),
            flags: flags,
            bestResponse: Vocabulary.canonical(response, in: Vocabulary.responses) ?? response,
            consistency: consistency,
            target: Vocabulary.canonical(target, in: Vocabulary.targets) ?? target,
            literal: json["literal"] as? String,
            realMeaning: json["real_meaning"] as? String,
            suggestedReply: json["suggested_reply"] as? String,
            memoryNote: nonEmpty(json["memory_note"]),
            reading: canonicalReading,
            confidence: number(json["confidence"]).map { min(3, max(1, $0)) },
            cultureNote: nonEmpty(json["why"]),
            replyGloss: nonEmpty(json["reply_zh"]),
            engine: engine,
            latencyMs: latencyMs
        )
    }

    /// 小模型有时会把别的字段的说明填进来，只接受四个规范值。
    static func canonicalConsistency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return ["反话", "撒娇", "没说完", "一致"].first { raw.contains($0) }
            ?? Vocabulary.canonical(raw, in: Vocabulary.consistency)
    }

    static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func probability(_ value: Any?) -> Double {
        if let s = value as? String {
            return ["true", "yes", "是", "1"].contains(s.lowercased()) ? 1 : (Double(s) ?? 0)
        }
        guard let n = number(value) else { return 0 }
        return n > 1 ? min(1, n / 100) : max(0, n)
    }
}

/// 最小的 JSON 值类型，用来在预设文件里保存示例答案。
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): n == n.rounded() ? try c.encode(Int(n)) : try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}
