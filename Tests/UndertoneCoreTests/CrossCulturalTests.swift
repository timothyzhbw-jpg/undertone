@testable import UndertoneCore
import XCTest

/// 跨文化视角：读英文消息的言外之意，用中文解释，给地道的英文回复。
final class CrossCulturalTests: XCTestCase {
    private let presets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../presets").standardized

    func testSubtextPresetMatchesSchemaAndVocabulary() throws {
        let prompt = try LLMPrompt.load(from: presets.appending(path: "subtext.llm.zh.json"))
        XCTAssertEqual(prompt.language, .en, "聊天记录是英文，用英文的框架")
        XCTAssertEqual(prompt.contextLength, 8192)
        XCTAssertGreaterThanOrEqual(prompt.examples.count, 10)
        let schema = try XCTUnwrap(prompt.schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(LLMAnalyzer.subtextKeys))
        XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys))
        let enums = { (key: String) in ((properties[key] as? [String: Any])?["enum"] as? [String]) ?? [] }
        // 模型直接输出中文规范值：每个选项都必须在词表里，配色、记忆和界面才认得出
        let tables: [(String, [Term])] = [("reading", Vocabulary.readings), ("emotion", Vocabulary.emotions),
                                          ("target", Vocabulary.targets), ("best_response", Vocabulary.responses)]
        for (key, terms) in tables {
            XCTAssertFalse(enums(key).isEmpty, key)
            for value in enums(key) { XCTAssertEqual(Vocabulary.canonical(value, in: terms), value, "\(key): \(value)") }
        }
        XCTAssertEqual(Set(enums("reading")), Set(Vocabulary.readings.map(\.zh)), "schema 和词表的话外音类型要一一对应")
        for example in prompt.examples {
            XCTAssertTrue(example.chat.contains("\n\nAnalyze only their latest message:\nThem: "), example.chat)
            XCTAssertEqual(Set(example.answer.keys), Set(LLMAnalyzer.subtextKeys), example.chat)
            for (key, _) in tables {
                if case .string(let value)? = example.answer[key] { XCTAssertTrue(enums(key).contains(value), "\(key): \(value)") }
            }
        }
    }

    /// few-shot 示例的格式必须和真实分析时一模一样，否则小模型会学歪。
    func testExampleChatsMatchLiveFormat() throws {
        let prompt = try LLMPrompt.load(from: presets.appending(path: "subtext.llm.zh.json"))
        let first = try XCTUnwrap(prompt.examples.first)
        let rendered = ChatState.render(
            context: [ChatMessage(speaker: .me, text: "Hi John, attached is our quotation for 5,000 units. Let me know if you have any questions.", top: 0)],
            latest: ChatMessage(speaker: .them, text: "Thanks for the quote. We'll review it internally and get back to you.", top: 1),
            relationship: "客户", language: .en)
        XCTAssertEqual(first.chat, rendered)
    }

    func testConfigUsesSubtextPreset() throws {
        var config = AnalyzerConfig()
        config.presets = presets
        let analyzer = try XCTUnwrap(config.makeAnalyzer(relationship: "老师") as? LLMAnalyzer)
        XCTAssertEqual(analyzer.prompt.contextLength, 8192)
        XCTAssertEqual((analyzer.backend as? OllamaBackend)?.contextLength, 8192, "提示词更长，本地模型的上下文要跟着加")
        let turns = try analyzer.turns(context: [], latest: ChatMessage(speaker: .them, text: "Let's circle back.", top: 0))
        XCTAssertTrue(turns.last!.content.hasPrefix("Relationship: professor\n"), turns.last!.content)

        config.llmPreset = "subtext.ft.zh.json"
        let tuned = try XCTUnwrap(config.makeAnalyzer() as? LLMAnalyzer)
        XCTAssertTrue(tuned.prompt.examples.isEmpty, "微调后的模型不带示例")
        XCTAssertEqual((tuned.backend as? OllamaBackend)?.contextLength, OllamaBackend.defaultContextLength)
    }

    func testReportParsesSubtextFields() throws {
        let latest = ChatMessage(speaker: .them, text: "That's an interesting idea.", top: 1)
        let r = try LLMAnalyzer.report(from: """
            {"literal": "这个想法挺有意思。", "why": "职场里常常是礼貌地否决。", "reading": "委婉拒绝", "real_meaning": "现在不会采纳。",
             "confidence": 2, "emotion": "平静", "intensity": 1, "target": "这件事", "best_response": "跟进推进",
             "suggested_reply": "Got it, thanks!", "reply_zh": "明白了，谢谢！", "memory_note": ""}
            """, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.reading, "委婉拒绝")
        XCTAssertEqual(r.confidence, 2)
        XCTAssertEqual(r.cultureNote, "职场里常常是礼貌地否决。")
        XCTAssertEqual(r.replyGloss, "明白了，谢谢！")
        XCTAssertEqual(r.bestResponse, "跟进推进")
        XCTAssertNil(r.memoryNote)
        XCTAssertNil(r.consistency)

        let sarcastic = try LLMAnalyzer.report(from: #"{"reading": "sarcastic", "confidence": 9, "why": "  "}"#,
                                               message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(sarcastic.reading, "反话", "英文标签也认")
        XCTAssertEqual(sarcastic.flags["sarcasm"], 1, "话外音是反话时也要推出反话信号")
        XCTAssertEqual(sarcastic.confidence, 3, "把握限制在 1–3")
        XCTAssertNil(sarcastic.cultureNote, "空白的说明不显示")

        // 情绪视角的旧结果没有这些字段，解码不能出错
        let old = try JSONDecoder().decode(EmotionReport.self, from: JSONEncoder().encode(
            EmotionReport(message: latest, emotion: "平静", intensity: 0, flags: [:], engine: "t", latencyMs: 1)))
        XCTAssertNil(old.reading)
    }

    func testReadingsDontSwallowEachOther() {
        XCTAssertEqual(Vocabulary.canonical("A polite no", in: Vocabulary.readings), "委婉拒绝")
        XCTAssertEqual(Vocabulary.canonical("not interested", in: Vocabulary.readings), nil, "「not interested」不能被认成有兴趣")
        XCTAssertEqual(Vocabulary.canonical("字面意思", in: Vocabulary.readings), "字面意思")
        XCTAssertEqual(Vocabulary.canonical("其实是委婉拒绝", in: Vocabulary.readings), "委婉拒绝")
        XCTAssertEqual(Vocabulary.display("还没决定", in: Vocabulary.readings, language: .en), "Not decided yet")
    }

    func testNewRelationships() {
        XCTAssertEqual(Vocabulary.canonical("buyer", in: Vocabulary.relationships), "客户")
        XCTAssertEqual(Vocabulary.canonical("Professor", in: Vocabulary.relationships), "老师")
        XCTAssertEqual(Vocabulary.english("客户", in: Vocabulary.relationships), "client")
        XCTAssertEqual(Vocabulary.canonical("boss", in: Vocabulary.relationships), "同事")
        for relation in relationshipChoices {
            XCTAssertEqual(Vocabulary.canonical(relation, in: Vocabulary.relationships), relation, relation)
        }
    }

    /// 外贸最常见的骗局：冒充客户或供应商说收款账户换了。正常的付款往来不能误报。
    func testTradeScamPatterns() {
        for text in ["Please note our bank account has changed due to an audit.",
                     "Kindly remit the balance to our new bank account below.",
                     "Our beneficiary details have been updated, please use the information below.",
                     "Please send the deposit to the new account today.",
                     "Pay the remaining 70% into our updated account.",
                     "Our company switched banks, please wire the deposit today.",
                     "Kindly transfer the balance to the account below.",
                     "Please update the beneficiary before releasing the payment.",
                     "You need to pay a small registration fee before we place the order.",
                     "Please direct all future payments to our new bank in Singapore.",
                     "IT here: please reply with your password so we can reset your account."] {
            XCTAssertTrue(MoneyNet.matches(text), text)
        }
        for text in ["Payment has been sent. Please find the bank slip attached.",
                     "We opened a new office in Hamburg.",
                     "I updated the account settings on the portal.",
                     "Received, thank you. We'll confirm the order quantity by Thursday.",
                     "The bank holiday pushed our shipment back a day.",
                     "Thanks for registering for the trade show!",
                     "Never share your password with anyone, including IT."] {
            XCTAssertFalse(MoneyNet.matches(text), text)
        }
    }
}

/// 「发之前看看」：检查用户要发的英文回复。
final class DraftCheckerTests: XCTestCase {
    private let presets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../presets").standardized

    func testDraftPresetMatchesSchemaAndLiveFormat() throws {
        let prompt = try LLMPrompt.load(from: presets.appending(path: "draft.llm.zh.json"))
        XCTAssertGreaterThanOrEqual(prompt.examples.count, 5)
        let schema = try XCTUnwrap(prompt.schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(DraftChecker.answerKeys))
        let verdicts = try XCTUnwrap((properties["verdict"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(verdicts), Set(Vocabulary.verdicts.map(\.zh)))
        for example in prompt.examples {
            XCTAssertEqual(Set(example.answer.keys), Set(DraftChecker.answerKeys), example.chat)
            XCTAssertTrue(example.chat.contains("\n\nMy draft reply:\n"), example.chat)
            if case .string(let verdict)? = example.answer["verdict"] { XCTAssertTrue(verdicts.contains(verdict), verdict) }
        }
        // 示例的格式必须和真实检查时一模一样
        let first = try XCTUnwrap(prompt.examples.first)
        let rendered = DraftChecker.render(
            context: [ChatMessage(speaker: .me, text: "The goods will be ready for shipment next Monday.", top: 0),
                      ChatMessage(speaker: .them, text: "Great, thanks for the update.", top: 1)],
            draft: "Please send me the balance payment today.", relationship: "客户")
        XCTAssertEqual(first.chat, rendered)
    }

    func testReviewParsing() throws {
        let r = try DraftChecker.review(from: """
            {"lands_as": "像在下命令。", "verdict": "too blunt", "issues": "太直接。", "rewrite": "Could you please arrange it today?", "rewrite_zh": "能今天安排吗？"}
            """, draft: "Send it today.", engine: "t", latencyMs: 1)
        XCTAssertEqual(r.verdict, "太生硬", "英文标签也认")
        XCTAssertTrue(r.rewriteDiffers)
        XCTAssertEqual(r.rewriteGloss, "能今天安排吗？")

        let same = try DraftChecker.review(from: #"{"verdict": "得体", "rewrite": "Thanks, got it!", "issues": ""}"#,
                                           draft: "thanks, got it", engine: "t", latencyMs: 1)
        XCTAssertFalse(same.rewriteDiffers, "只差大小写和标点时不再重复显示")
        XCTAssertNil(same.issues)
    }

    func testDraftCheckerUsesConfiguredBackend() throws {
        var config = AnalyzerConfig()
        config.presets = presets
        let checker = try config.makeDraftChecker(relationship: "老师")
        let turns = try checker.turns(context: [], draft: "hey prof")
        XCTAssertTrue(turns.last!.content.hasPrefix("Relationship: professor\n"))
        XCTAssertTrue(turns.last!.content.hasSuffix("My draft reply:\nhey prof"))
        XCTAssertEqual(turns.count, checker.prompt.examples.count * 2 + 1)
    }
}

/// 模型解释英文说法时常在字符串里直接写英文引号，JSON 要能修好。
final class InnerQuoteRepairTests: XCTestCase {
    func testUnescapedQuotesInsideStrings() throws {
        let pretty = """
            {
              "literal": "让我先跟我的经理确认一下。",
              "why": "在商务沟通中，使用"Let me run this by my manager"是标准流程，"next week"是常见的时间承诺。",
              "reading": "还没决定",
              "confidence": 2
            }
            """
        let r = try LLMAnalyzer.report(from: pretty, message: ChatMessage(speaker: .them, text: "x", top: 0), engine: "t", latencyMs: 1)
        XCTAssertEqual(r.reading, "还没决定")
        XCTAssertEqual(r.cultureNote, #"在商务沟通中，使用"Let me run this by my manager"是标准流程，"next week"是常见的时间承诺。"#)

        let compact = #"{"why": "说"no, thanks"其实是拒绝", "reading": "委婉拒绝", "confidence": 3}"#
        let c = try LLMAnalyzer.report(from: compact, message: ChatMessage(speaker: .them, text: "x", top: 0), engine: "t", latencyMs: 1)
        XCTAssertEqual(c.reading, "委婉拒绝")
        XCTAssertEqual(c.cultureNote, #"说"no, thanks"其实是拒绝"#)

        // 本来就合法的 JSON 不受影响
        XCTAssertEqual(LLMAnalyzer.escapeInnerQuotes(#"{"a": "b \"c\"", "d": [1, "e"]}"#), #"{"a": "b \"c\"", "d": [1, "e"]}"#)
    }
}

/// 微调模型只管读话外音；发之前看看用标准模型。
final class TunedModelConfigTests: XCTestCase {
    private let presets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../presets").standardized

    func testTunedModelUsesShortPromptAndStandardModelForDrafts() throws {
        var config = AnalyzerConfig()
        config.presets = presets
        config.llm = .ollama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: TunedModel.name)
        config.llmPreset = TunedModel.preset
        config.auxiliaryLLM = .ollama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: TunedModel.standardModel)
        let analyzer = try XCTUnwrap(config.makeAnalyzer() as? LLMAnalyzer)
        XCTAssertEqual((analyzer.backend as? OllamaBackend)?.model, TunedModel.name)
        XCTAssertTrue(analyzer.prompt.examples.isEmpty)
        let checker = try config.makeDraftChecker()
        XCTAssertEqual((checker.backend as? OllamaBackend)?.model, TunedModel.standardModel)
        XCTAssertTrue(TunedModel.isTuned("undertone-subtext:latest"))
        XCTAssertFalse(TunedModel.isTuned("qwen3.5:4b"))
    }
}

/// 截图 → 粘贴模式的文字。
final class ScreenshotTranscriptTests: XCTestCase {
    func testChatScreenshotKeepsSpeakers() {
        let messages = [
            ChatMessage(speaker: .me, text: "Here is the quote.", top: 0.1),
            ChatMessage(speaker: .them, text: "Thanks!\nWe'll review it.", sender: "John", top: 0.3),
            ChatMessage(speaker: .them, text: "Let me check with my team.", top: 0.5),
        ]
        let text = ScreenshotTranscript.make(messages: messages, ocrText: [])
        XCTAssertEqual(text, "Me: Here is the quote.\nJohn: Thanks! We'll review it.\nJohn: Let me check with my team.")
        let parsed = ChatTranscript.parse(text)
        XCTAssertEqual(parsed.messages.first?.speaker, .me)
        XCTAssertEqual(parsed.messages.last?.speaker, .them)
        XCTAssertEqual(parsed.messages.last?.text, "Let me check with my team.")
    }

    func testOneSidedScreenshotBecomesOneMessage() {
        // 邮件被认成三段「对方」：连成一条，落款不能变成「最新一条」
        let email = [ChatMessage(speaker: .them, text: "Hi Lily,", top: 0),
                     ChatMessage(speaker: .them, text: "We will not be moving forward\nat this time.", top: 1),
                     ChatMessage(speaker: .them, text: "Best regards, Mark", top: 2)]
        let text = ScreenshotTranscript.make(messages: email, ocrText: [])
        XCTAssertEqual(text, "Hi Lily, We will not be moving forward at this time. Best regards, Mark")
        XCTAssertEqual(ChatTranscript.parse(text).messages.count, 1)
    }

    func testUnnamedBubblesGetAPlaceholder() {
        let text = ScreenshotTranscript.make(messages: [ChatMessage(speaker: .them, text: "ok", top: 0),
                                                        ChatMessage(speaker: .me, text: "sure", top: 1),
                                                        ChatMessage(speaker: .them, text: "thanks", top: 2)], ocrText: [])
        XCTAssertEqual(text, "Them: ok\nMe: sure\nThem: thanks")
        XCTAssertEqual(ChatTranscript.parse(text).messages.count, 3)
    }

    func testEmailScreenshotBecomesOneMessage() {
        let text = ScreenshotTranscript.make(messages: [], ocrText: ["Hi Lily,", "Thanks for the quote. ", "", "We'll circle back next quarter."])
        XCTAssertEqual(text, "Hi Lily, Thanks for the quote. We'll circle back next quarter.")
        XCTAssertEqual(ChatTranscript.parse(text).messages.last?.speaker, .them)
    }
}

/// 绝望感一类的轻生信号：认真对待；日常的抱怨和夸张不能触发。
final class HopelessnessSafetyTests: XCTestCase {
    func testHopelessnessIsCaught() {
        for text in ["i'm just tired of everything. i don't think it's ever going to get better",
                     "it's never going to get better, is it",
                     "honestly i'm so tired of it all"] {
            XCTAssertTrue(SafetyNet.matches(text), text)
        }
        for text in ["this traffic is never going to end lol", "I'm tired of this printer",
                     "the weather is going to get better tomorrow", "sick of meetings today 🙄",
                     "Things are getting better at the new office"] {
            XCTAssertFalse(SafetyNet.matches(text), text)
        }
    }
}
