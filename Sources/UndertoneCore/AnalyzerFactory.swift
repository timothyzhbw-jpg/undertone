import Foundation

/// 关系选择条上的关系（中文规范值）：同一句英文，对客户、上司、老师、朋友说，意思常常不一样。
public let relationshipChoices = ["不确定", "客户", "同事", "老师", "同学", "朋友"]

/// 生成式大模型从哪来。
public enum LLMSource: Sendable {
    case ollama(baseURL: URL, model: String)
    case openAICompatible(baseURL: URL, model: String, apiKey: String, supportsJSONSchema: Bool, providerName: String)
    case anthropic(model: String, apiKey: String)

    public static let localDefault = LLMSource.ollama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "qwen3.5:4b")

    public func backend() -> ChatBackend {
        switch self {
        case .ollama(let url, let model):
            OllamaBackend(baseURL: url, model: model)
        case .openAICompatible(let url, let model, let key, let schema, let provider):
            OpenAICompatibleBackend(baseURL: url, model: model, apiKey: key, supportsJSONSchema: schema, providerName: provider)
        case .anthropic(let model, let key):
            AnthropicBackend(model: model, apiKey: key)
        }
    }
}

/// OpenAI 兼容服务的预设：选一个就自动填好地址和常用模型（模型名可以改）。
public struct OpenAIPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let model: String
    public let supportsJSONSchema: Bool

    public static var all: [OpenAIPreset] { [
        OpenAIPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-5.5", supportsJSONSchema: true),
        OpenAIPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat", supportsJSONSchema: false),
        OpenAIPreset(id: "qwen", name: L("通义千问", "Qwen (DashScope)"), baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus", supportsJSONSchema: false),
        OpenAIPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "", supportsJSONSchema: false),
        OpenAIPreset(id: "custom", name: L("自定义", "Custom"), baseURL: "", model: "", supportsJSONSchema: false),
    ] }

    public static func named(_ id: String) -> OpenAIPreset { all.first { $0.id == id } ?? all[0] }
}

/// 本地微调模型（train/ 训练、train/ollama/Modelfile.subtext 导入 Ollama）。只学了读话外音：用短提示、不带示例；
/// 「发之前看看」和看表情图这些它没学过的事，交给标准模型。
public enum TunedModel {
    public static let name = "undertone-subtext"
    public static let preset = "subtext.ft.zh.json"
    public static let standardModel = "qwen3.5:4b"
    public static func isTuned(_ model: String) -> Bool { model.hasPrefix("undertone-") }
}

/// 创建分析器所需的全部配置。
public struct AnalyzerConfig: Sendable {
    public var llm: LLMSource = .localDefault
    public var presets: URL = Presets.directory
    /// 大模型提示词文件；评测微调过的模型时换成 subtext.ft.zh.json。
    public var llmPreset = "subtext.llm.zh.json"
    /// 辅助任务（发之前看看、看表情图）用的模型；nil 时和读话外音用同一个。用微调模型时这里是标准模型。
    public var auxiliaryLLM: LLMSource?

    public init() {}

    /// 读话外音的分析器。memory 为联系人记忆摘要（ContactMemory.promptSummary），会写进给模型的上下文。
    public func makeAnalyzer(relationship: String? = nil, memory: String? = nil) throws -> EmotionAnalyzer {
        let prompt = try LLMPrompt.load(from: presets.appending(path: llmPreset))
        return LLMAnalyzer(backend: backend(for: prompt), prompt: prompt, relationship: relationship, memory: memory)
    }

    /// 「发之前看看」：检查用户要发的英文回复。
    public func makeDraftChecker(relationship: String? = nil) throws -> DraftChecker {
        let prompt = try LLMPrompt.load(from: presets.appending(path: "draft.llm.zh.json"))
        return DraftChecker(backend: backend(for: prompt, source: auxiliaryLLM ?? llm), prompt: prompt, relationship: relationship)
    }

    /// 提示词更长的预设可以要更大的本地上下文。
    private func backend(for prompt: LLMPrompt, source: LLMSource? = nil) -> ChatBackend {
        let backend = (source ?? llm).backend()
        guard var ollama = backend as? OllamaBackend, let length = prompt.contextLength else { return backend }
        ollama.contextLength = max(length, OllamaBackend.defaultContextLength)
        return ollama
    }
}

/// 预设文件位置：环境变量 UNDERTONE_PRESETS > .app 内 Resources/presets > 当前目录 presets/。
public enum Presets {
    public static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["UNDERTONE_PRESETS"] {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "presets"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "presets")
    }
}
