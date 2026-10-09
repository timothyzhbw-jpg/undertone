import UndertoneCore
import Foundation

/// 批量分析一个 JSONL 文件，走和应用里一样的代码路径（分析引擎 + 两层关键词兜底）。
/// 用法：Undertone --eval eval/crosscultural.jsonl 输出.jsonl
/// 输入每行：{"text": "对方说的英文", "relationship": "client", "context": "Me: …\nThem: …"}（后两项可选）
///
/// 默认用本地大模型。环境变量：
///   UNDERTONE_LLM_PRESET=subtext.ft.zh.json、UNDERTONE_OPENAI_URL=http://127.0.0.1:8080/v1（评测 train/ 里微调的模型）
///   UNDERTONE_OLLAMA_MODEL=undertone-subtext（导入 Ollama 的微调模型，配 UNDERTONE_LLM_PRESET=subtext.ft.zh.json）
/// 每行写 "draft" 而不是 "text" 时，测的是「发之前看看」（评测集 eval/draft.jsonl）。
enum EvalRunner {
    static func config(_ env: [String: String] = ProcessInfo.processInfo.environment) -> AnalyzerConfig {
        var config = AnalyzerConfig()
        if let preset = env["UNDERTONE_LLM_PRESET"], !preset.isEmpty { config.llmPreset = preset }
        // 换一个本机 Ollama 模型（例如导入的微调模型 undertone-subtext）
        if let model = env["UNDERTONE_OLLAMA_MODEL"], !model.isEmpty {
            config.llm = .ollama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: model)
        }
        // 本机的 OpenAI 兼容服务（例如 mlx_lm.server 跑微调后的模型），不需要真的密钥
        if let url = env["UNDERTONE_OPENAI_URL"].flatMap(URL.init(string:)) {
            config.llm = .openAICompatible(baseURL: url, model: env["UNDERTONE_OPENAI_MODEL"] ?? "default_model", apiKey: "local",
                                           supportsJSONSchema: false, providerName: "local")
        }
        return config
    }

    struct Input: Decodable {
        var id: Int?
        var text: String?
        var relationship: String?
        var context: String?
        /// 「发之前看看」的评测（eval/draft.jsonl）：要检查的英文草稿，结果是 DraftReview。
        var draft: String?
    }

    static func run(input: URL, output: URL) async throws {
        LLMAnalyzer.dumpUnparsable = true
        let lines = try String(contentsOf: input, encoding: .utf8).split(whereSeparator: \.isNewline)
        let config = config()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var results: [Data] = []
        for (index, line) in lines.enumerated() {
            guard let item = try? decoder.decode(Input.self, from: Data(line.utf8)) else { continue }
            let context = (item.context ?? "").split(whereSeparator: \.isNewline).map { line -> ChatMessage in
                let text = String(line)
                for prefix in ["我：", "Me:"] where text.hasPrefix(prefix) {
                    return ChatMessage(speaker: .me, text: text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces), top: 0)
                }
                let theirs = ["对方：", "Them:"].first { text.hasPrefix($0) }.map { text.dropFirst($0.count) } ?? Substring(text)
                return ChatMessage(speaker: .them, text: theirs.trimmingCharacters(in: .whitespaces), top: 0)
            }
            if let draft = item.draft {
                do {
                    let review = try await config.makeDraftChecker(relationship: item.relationship).review(draft: draft, context: context)
                    results.append(try encoder.encode(review))
                    FileHandle.standardError.write(Data("\(index + 1)/\(lines.count) \(review.verdict)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("\(index + 1)/\(lines.count) \(L("失败", "failed"))：\(error.localizedDescription)\n".utf8))
                    results.append(Data(#"{"error": true}"#.utf8))
                }
                continue
            }
            guard let text = item.text else { continue }
            let latest = ChatMessage(speaker: .them, text: text, top: 1)
            let analyzer = try config.makeAnalyzer(relationship: item.relationship)
            do {
                let analyzed = try await analyzer.analyze(context: context, latest: latest)
                let report = MoneyNet.apply(to: SafetyNet.apply(to: analyzed))
                results.append(try encoder.encode(report))
                FileHandle.standardError.write(Data("\(index + 1)/\(lines.count) \(report.reading ?? report.emotion)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("\(index + 1)/\(lines.count) \(L("失败", "failed"))：\(error.localizedDescription)\n".utf8))
                results.append(Data(#"{"error": true}"#.utf8))
            }
        }
        try Data(results.map { $0 + Data("\n".utf8) }.reduce(Data(), +)).write(to: output)
    }
}
