@testable import UndertoneCore
import XCTest

/// 英文版：英文标签换回中文规范值、英文的聊天记录框架、英文预设、英文安全网和粘贴格式。
final class EnglishTests: XCTestCase {
    private let presets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../presets").standardized

    override func tearDown() {
        AppLanguage.current = .zh
        super.tearDown()
    }

    func testEnglishLabelsMapToCanonicalValues() throws {
        let latest = ChatMessage(speaker: .them, text: "fine, whatever", top: 1)
        let r = try LLMAnalyzer.report(
            from: #"{"emotion": "hurt", "consistency": "sarcastic", "target": "me", "best_response": "apologize", "angry_at_me": true}"#,
            message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.emotion, "委屈")
        XCTAssertEqual(r.consistency, "反话")
        XCTAssertEqual(r.flags["sarcasm"], 1, "英文的 sarcastic 也要推出反话信号")
        XCTAssertEqual(r.target, "我")
        XCTAssertEqual(r.bestResponse, "真诚道歉")
        XCTAssertEqual(r.flags["angry_at_me"], 1)
    }

    func testModelLabelVariantsAreRecognised() {
        XCTAssertEqual(Vocabulary.canonical("Holding back", in: Vocabulary.consistency), "没说完")
        XCTAssertEqual(Vocabulary.canonical("not sincere, sarcastic", in: Vocabulary.consistency), "反话")
        XCTAssertEqual(Vocabulary.canonical("someone else", in: Vocabulary.targets), "别人")
        XCTAssertEqual(Vocabulary.canonical("give_space", in: Vocabulary.responses), "给对方空间")
        XCTAssertEqual(Vocabulary.canonical("Verify it's them", in: Vocabulary.responses), "核实身份")
        XCTAssertEqual(Vocabulary.canonical("Partner", in: Vocabulary.relationships), "恋人")
        XCTAssertEqual(Vocabulary.canonical("委屈", in: Vocabulary.emotions), "委屈")
        XCTAssertNil(Vocabulary.canonical("purple", in: Vocabulary.emotions))
        XCTAssertNil(Vocabulary.canonical("  ", in: Vocabulary.emotions))
    }

    func testDisplayUsesEnglishLabels() {
        XCTAssertEqual(Vocabulary.display("委屈", in: Vocabulary.emotions, language: .en), "Hurt")
        XCTAssertEqual(Vocabulary.display("委屈", in: Vocabulary.emotions, language: .zh), "委屈")
        XCTAssertEqual(Vocabulary.display("我", in: Vocabulary.targets, language: .en), "at you")
        XCTAssertEqual(Vocabulary.display("核实身份", in: Vocabulary.responses, language: .en), "Verify it's them")
        XCTAssertEqual(Vocabulary.display("先接住 TA", in: Vocabulary.responses, language: .en), "先接住 TA", "不在表里的原样返回")
        XCTAssertEqual(EmotionFlag.selfHarm.title(in: .en), "Self-harm risk")
        AppLanguage.current = .en
        XCTAssertEqual(EmotionFlag.asksMoney.title, "Payment or account request")
        XCTAssertEqual(L("中文", "English"), "English")
    }

    func testRendersEnglishChat() {
        let context = [ChatMessage(speaker: .me, text: "Working late tonight", top: 0)]
        let latest = ChatMessage(speaker: .them, text: "ok[表情：slight smile]", top: 1)
        let text = ChatState.render(context: context, latest: latest, relationship: "恋人", language: .en)
        XCTAssertTrue(text.hasPrefix("Relationship: partner\n"), text)
        XCTAssertTrue(text.contains("Me: Working late tonight"))
        XCTAssertTrue(text.hasSuffix("Analyze only their latest message:\nThem: ok[emoji: slight smile]"), text)
        XCTAssertFalse(ChatState.render(context: [], latest: latest, relationship: "not sure", language: .en).contains("Relationship"))
        XCTAssertTrue(ChatState.render(context: [], latest: latest, relationship: "不确定").hasPrefix("以下是"), "中文版不变")
    }

    func testPlaceholdersInEnglish() {
        XCTAssertEqual(Placeholder.localized("[语音 5秒]", .en), "[voice 5s]")
        XCTAssertEqual(Placeholder.localized("[语音]", .en), "[voice]")
        XCTAssertEqual(Placeholder.localized("[语音转文字] where are you", .en), "[voice-to-text] where are you")
        XCTAssertEqual(Placeholder.localized("[表情包：cat covering ears]", .en), "[sticker: cat covering ears]")
        XCTAssertEqual(Placeholder.localized("ok[表情][表情]", .en), "ok[emoji][emoji]")
        XCTAssertEqual(Placeholder.localized("what time（引用：Alex: working late）", .en), "what time (replying to: Alex: working late)")
        XCTAssertEqual(Placeholder.localized("[表情]", .zh), "[表情]")
    }


    func testEnglishMemorySummary() {
        var memory = ContactMemory(name: "Mia")
        memory.notes = [.init(text: "Interview next Wednesday", source: .user)]
        let report = EmotionReport(message: ChatMessage(speaker: .them, text: "k", top: 0), emotion: "冷淡", intensity: 1,
                                   flags: ["cold_distance": 1], consistency: "没说完", engine: "t", latencyMs: 0)
        memory.record(report)
        memory.record(report)
        let summary = memory.promptSummary(language: .en) ?? ""
        XCTAssertTrue(summary.hasPrefix("What I remember about them"), summary)
        XCTAssertTrue(summary.contains("Interview next Wednesday"))
        XCTAssertTrue(summary.contains("cold ×2"), summary)
        XCTAssertTrue(summary.contains("Losing interest ×2"), summary)
        XCTAssertTrue(summary.contains("\"k\" → cold, holding back"), summary)
        XCTAssertNil(summary.range(of: #"\p{Han}"#, options: .regularExpression), "英文摘要里不能夹中文")
    }

    func testEnglishCrisisPhrasesAreCaught() {
        for text in ["honestly i don't want to be alive anymore",
                     "I've been saving up my sleeping pills, thanks for everything",
                     "everyone would be better off without me",
                     "nobody would even notice if I disappeared",
                     "I just want to fall asleep and never wake up",
                     "I’m just a burden to everyone",
                     "I cut myself again, it's the only thing that helps",
                     "there's no point in living like this",
                     "sometimes i think everyone would be better off if i just wasn't around",
                     "i just want it all to stop"] {
            XCTAssertTrue(SafetyNet.matches(text), text)
        }
    }

    /// 日常夸张不能触发：给开玩笑的人弹自伤提醒，用户很快就不信这个提醒了。
    func testEnglishHyperboleIsNotFlagged() {
        for text in ["LMAO I'm dead 💀", "this homework is killing me", "I could die of embarrassment",
                     "ugh kill me now", "I want to die, this exam was brutal", "I'm so done with this week",
                     "that concert was to die for"] {
            XCTAssertFalse(SafetyNet.matches(text), text)
        }
    }

    func testEnglishMoneyRequests() {
        for text in ["can you lend me $300? i'll pay you back tomorrow", "just send me the money to this account",
                     "what's the 6-digit code they just texted you?", "zelle me 200 asap", "can you grab me some gift cards",
                     "what's your bank account number"] {
            XCTAssertTrue(MoneyNet.matches(text), text)
        }
        for text in ["can you lend me a hand with the move?", "I'll venmo you for dinner", "send me the pics from last night"] {
            XCTAssertFalse(MoneyNet.matches(text), text)
        }
    }

    func testEnglishTranscriptFormats() {
        let parsed = ChatTranscript.parse("""
        [10/3/26, 9:38 PM] Mia: it's fine, do your thing
        [10/3/26, 9:39 PM] Me: let me make it up to you later?
        Today 9:40 PM
        Mia — Today at 9:41 PM
        whatever, as long as you're happy
        Delivered
        """)
        XCTAssertEqual(parsed.messages.map(\.speaker), [.them, .me, .them])
        XCTAssertEqual(parsed.messages.map(\.text),
                       ["it's fine, do your thing", "let me make it up to you later?", "whatever, as long as you're happy"])
        XCTAssertEqual(parsed.names, ["Mia"])
    }

    func testSentencesWithTimesAreNotSpeakers() {
        let parsed = ChatTranscript.parse("Amy: dinner?\nmeet me at 7:30\nok see you at 7:30 PM")
        XCTAssertEqual(parsed.messages.count, 1)
        XCTAssertEqual(parsed.messages[0].text, "dinner?\nmeet me at 7:30\nok see you at 7:30 PM")
    }

    func testEnglishMemoryHints() {
        XCTAssertEqual(MemoryHints.suggestion(for: "btw my interview is next Wednesday at 10"), "my interview is next Wednesday at 10")
        XCTAssertNotNil(MemoryHints.suggestion(for: "I'm allergic to shellfish fyi"))
        XCTAssertNil(MemoryHints.suggestion(for: "the examples were weird"))
        XCTAssertNil(MemoryHints.suggestion(for: "lol ok"))
    }

    // MARK: 截图里的英文时间、状态和在线状态

    func testEnglishTimestampsAndReceiptsAreNotMessages() {
        for text in ["9:41 PM", "9:41PM", "Yesterday 9:41 PM", "Today at 10:02 a.m.", "Mon 9:41 PM", "Oct 3, 2026 at 9:41 PM",
                     "10/3/26, 9:41 PM", "Delivered", "Read 9:42 PM", "Seen yesterday 8:15 pm", "21:05", "昨天 21:05"] {
            XCTAssertTrue(ChatParser.isTimestamp(text), text)
        }
        for text in ["Monday", "see you at 9", "read it yet?", "sent you the file", "I'll be there by 9:30 tho", "ok"] {
            XCTAssertFalse(ChatParser.isTimestamp(text), text)
        }
    }

    /// 气泡外面左边的「9:41 PM」不能变成对方的最新一条。
    func testTimeUnderTheirBubbleIsNotTheirLatestMessage() {
        let lines = [
            OCRLine(text: "no it's fine, whatever", box: CGRect(x: 0.08, y: 0.40, width: 0.40, height: 0.03)),
            OCRLine(text: "9:41 PM", box: CGRect(x: 0.08, y: 0.45, width: 0.10, height: 0.02)),
            OCRLine(text: "sorry!!", box: CGRect(x: 0.70, y: 0.55, width: 0.20, height: 0.03)),
            OCRLine(text: "Delivered", box: CGRect(x: 0.78, y: 0.60, width: 0.12, height: 0.02)),
        ]
        let messages = ChatParser.parse(lines)
        XCTAssertEqual(messages.last { $0.speaker == .them }?.text, "no it's fine, whatever")
        XCTAssertEqual(messages.filter { $0.speaker == .me }.map(\.text), ["sorry!!"])
    }

    func testPresenceLinesAreNotContactNames() {
        let lines = [
            OCRLine(text: "Mia Chen", box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3)),
            OCRLine(text: "Active now", box: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2)),
        ]
        XCTAssertEqual(ContactNameDetector.detect(lines), "Mia Chen")
        for text in ["Active 5m ago", "online", "last seen today at 9:41 PM", "typing…", "Mia is typing...", "9:41 PM", "4 members"] {
            XCTAssertNil(ContactNameDetector.clean(text), text)
        }
        XCTAssertEqual(ContactNameDetector.clean("Online Store"), "Online Store")
        XCTAssertEqual(ContactNameDetector.clean("Mom"), "Mom")
    }
}
