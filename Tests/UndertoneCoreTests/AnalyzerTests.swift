@testable import UndertoneCore
import XCTest

final class AnalyzerTests: XCTestCase {
    private let latest = ChatMessage(speaker: .them, text: "没事，你玩得开心就好", top: 0.8)

    func testLLMOutputIsParsedLeniently() throws {
        let content = """
        好的，结果如下：{"emotion":"委屈","intensity":"2","consistency":"反话","target":"我",
        "angry_at_me":"true","needs_comfort":1,"self_harm":false,"testing":85,
        "real_meaning":"其实很失落","best_response":"真诚道歉","suggested_reply":"对不起"}
        """
        let r = try LLMAnalyzer.report(from: content, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.emotion, "委屈")
        XCTAssertEqual(r.intensity, 2)
        XCTAssertEqual(r.consistency, "反话")
        XCTAssertEqual(r.target, "我")
        XCTAssertEqual(r.flags["angry_at_me"], 1)
        XCTAssertEqual(r.flags["needs_comfort"], 1)
        XCTAssertEqual(r.flags["testing"], 0.85)
        XCTAssertEqual(r.flags["self_harm"], 0)
        XCTAssertEqual(r.flags["sarcasm"], 1, "反话应自动带上阴阳怪气标记")
        XCTAssertEqual(r.activeFlags(), [.angryAtMe, .sarcasm, .needsComfort, .testing])
    }

    func testLLMOutputWithoutJSONThrows() {
        XCTAssertThrowsError(try LLMAnalyzer.report(from: "抱歉，我无法回答", message: latest, engine: "t", latencyMs: 1))
    }

    func testConsistencyIsNormalized() throws {
        let messy = #"{"emotion":"冷淡","consistency":"敷衍或不想争了（「哦」「都行」「你看着办」）"}"#
        XCTAssertNil(try LLMAnalyzer.report(from: messy, message: latest, engine: "t", latencyMs: 1).consistency)
        let wrapped = #"{"emotion":"委屈","consistency":"反话（嘴上说没事）"}"#
        XCTAssertEqual(try LLMAnalyzer.report(from: wrapped, message: latest, engine: "t", latencyMs: 1).consistency, "反话")
    }

    func testCurlyQuoteDelimitersAreRepaired() throws {
        let broken = #"{"emotion": "生气", "real_meaning": “想控制我”, "suggested_reply": "我们聊聊“信任”这件事吧”}"#
        let r = try LLMAnalyzer.report(from: broken, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.realMeaning, "想控制我")
        XCTAssertEqual(r.suggestedReply, "我们聊聊“信任”这件事吧", "字符串内部的中文引号要保留")
    }

    /// 值以英文引文开头或结尾时，小模型会把开头或结尾的引号写成 \"（日文解释里实际出现过）。
    func testStrayEscapedQuoteAtValueBoundaryIsRepaired() throws {
        let broken = #"{"lands_as": \"look\" が二回使われています。", "verdict": "grammar issues", "issues": "\"look look\" は正しくありません。\", "rewrite": "Can you take a look?"}"#
        let object = try XCTUnwrap(LLMAnalyzer.parseObject(broken))
        XCTAssertEqual(object["lands_as"] as? String, #""look" が二回使われています。"#)
        XCTAssertEqual(object["issues"] as? String, #""look look" は正しくありません。"#)
        XCTAssertEqual(object["rewrite"] as? String, "Can you take a look?")
        // 本来合法、只是字符串里有 \", 的 JSON 不受影响
        let fine = #"{"a": "say \"hi\", then go", "b": "x"}"#
        XCTAssertEqual(LLMAnalyzer.parseObject(fine)?["a"] as? String, #"say "hi", then go"#)
    }

    func testExamplesAreEncodedInPromptOrder() throws {
        let text = try LLMAnalyzer.encodeInOrder([
            "suggested_reply": .string("好"), "emotion": .string("开心"), "literal": .string("嗯"), "intensity": .number(1),
        ])
        XCTAssertEqual(text, #"{"literal": "嗯", "emotion": "开心", "intensity": 1, "suggested_reply": "好"}"#)
    }

    func testIntensityIsClamped() throws {
        let r = try LLMAnalyzer.report(from: #"{"emotion":"生气","intensity":9}"#, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.intensity, 3)
        XCTAssertTrue(r.activeFlags().isEmpty)
    }


    func testStateIncludesRelationshipAndSpeakers() {
        let context = [
            ChatMessage(speaker: .me, text: "今晚聚餐", top: 0.1),
            ChatMessage(speaker: .them, text: "哦", sender: "小美", top: 0.3),
        ]
        let text = ChatState.render(context: context, latest: latest, relationship: "恋人")
        XCTAssertTrue(text.hasPrefix("双方关系：恋人\n"))
        XCTAssertTrue(text.contains("我：今晚聚餐\n对方（小美）：哦"))
        XCTAssertTrue(text.hasSuffix("需要分析的是对方最新这条：\n对方：没事，你玩得开心就好"))
        XCTAssertFalse(ChatState.render(context: [], latest: latest, relationship: "不确定").contains("双方关系"))
    }

    func testMediaNoteOnlyWhenChatHasEmojiOrVoice() throws {
        let prompt = LLMPrompt(system: "系统", mediaNote: "（说明：方括号）", examples: [])
        let analyzer = LLMAnalyzer(backend: OllamaBackend(), prompt: prompt)
        let me = ChatMessage(speaker: .me, text: "今晚加班", top: 0)
        let plain = try analyzer.turns(context: [me], latest: ChatMessage(speaker: .them, text: "好的", top: 1))
        XCTAssertFalse(plain.last!.content.contains("说明"), "纯文字消息的提示和以前完全一样")
        for text in ["好的[表情：微笑]", "[语音转文字] 你几点回", "好的[微笑]"] {
            let turns = try analyzer.turns(context: [me], latest: ChatMessage(speaker: .them, text: text, top: 1))
            XCTAssertTrue(turns.last!.content.hasSuffix("（说明：方括号）"), text)
        }
        XCTAssertFalse(LLMAnalyzer.hasMedia("我觉得 [ 这个 ] 还行"))
    }

}

final class SafetyNetTests: XCTestCase {
    /// duxin 评测集里的 5 条轻生正例（其中「攒药」一条 Kev 判为 0.00）。
    func testCatchesDuxinCrisisCases() {
        for text in ["男朋友：你不回我消息的话我就去死，你自己看着办",
                     "朋友：活着真的好累，有时候真想一觉睡过去再也不醒来",
                     "同学：我已经把药都攒够了，谢谢你这几年对我好",
                     "网友：我觉得我就是个累赘，没有我大家都会过得更好",
                     "表妹：我又划了自己，只有这样才能不那么难受"] {
            XCTAssertTrue(SafetyNet.matches(text), text)
        }
    }

    func testEverydayHyperboleIsNotACrisis() {
        for text in ["作业多到我想死", "尴尬得想去死", "这剧好看到我想跳下去", "饿死了快点吃饭", "笑死我了", "我要死了明天就due了",
                     "你去死吧哈哈哈"] {
            XCTAssertFalse(SafetyNet.matches(text), text)
        }
    }

    func testPassiveIdeationIsCaught() {
        XCTAssertTrue(SafetyNet.matches("有时候觉得我消失了也不会有人在意吧"))
        XCTAssertTrue(SafetyNet.matches("真的 撑不下去了"))
        XCTAssertTrue(SafetyNet.matches("活着没什么意思"))
    }

    func testHyperboleIsIgnored() {
        XCTAssertFalse(SafetyNet.matches("啊啊啊我要死了，明天就due了"))
        XCTAssertFalse(SafetyNet.matches("哈哈哈笑死，气死我了"))
    }

    func testApplyRaisesButNeverLowers() {
        let message = ChatMessage(speaker: .them, text: "我不在了大家会更好", top: 0)
        let low = EmotionReport(message: message, emotion: "难过", intensity: 3, flags: ["self_harm": 0.1], engine: "t", latencyMs: 0)
        XCTAssertEqual(SafetyNet.apply(to: low).flags["self_harm"], SafetyNet.probability)
        let high = EmotionReport(message: message, emotion: "难过", intensity: 3, flags: ["self_harm": 1], engine: "t", latencyMs: 0)
        XCTAssertEqual(SafetyNet.apply(to: high).flags["self_harm"], 1)
    }
}

final class MoneyNetTests: XCTestCase {
    private func report(_ text: String, money: Double = 0) -> EmotionReport {
        EmotionReport(message: ChatMessage(speaker: .them, text: text, top: 0), emotion: "平静", intensity: 0,
                      flags: ["asks_money": money], engine: "t", latencyMs: 0)
    }

    func testCatchesMoneyAndAccountRequests() {
        for text in ["能不能先借我 3000，明天还你", "直接转这个卡号 6222 0000 1234 5678", "把验证码发我一下",
                     "先垫付一下运费", "你的支付密码是多少", "转账给我就行", "先交个保证金才能提现"] {
            XCTAssertTrue(MoneyNet.matches(text), text)
        }
        XCTAssertEqual(MoneyNet.apply(to: report("先借我 500 应应急")).flags["asks_money"], SafetyNet.probability)
        XCTAssertEqual(MoneyNet.apply(to: report("借我 500", money: 1)).flags["asks_money"], 1, "不覆盖模型更高的判断")
        XCTAssertEqual(MoneyNet.apply(to: report("Interesting. Let me run this by my team and circle back.", money: 0.9)).flags["asks_money"], 0,
                       "消息里没提钱和账户时，不信模型报的「要钱」")
        XCTAssertEqual(MoneyNet.apply(to: report("Please settle the invoice this week.", money: 0.9)).flags["asks_money"], 0.9)
    }

    func testIgnoresEverydayTalk() {
        for text in ["把你手机密码告诉我，不然就是心里有鬼", "借我充电宝用一下", "群里发红包了快抢", "这个月工资还没发"] {
            XCTAssertFalse(MoneyNet.matches(text), text)
        }
    }
}

final class CombinedAnalyzerTests: XCTestCase {
    struct Fake: EmotionAnalyzer {
        var name: String
        var flags: [String: Double]
        var fails = false

        func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
            if fails { throw AnalyzerError.badResponse("down") }
            return EmotionReport(message: latest, emotion: "难过", intensity: 2, flags: flags,
                                 suggestedReply: name, engine: name, latencyMs: 10)
        }
    }

    private let latest = ChatMessage(speaker: .them, text: "你敢去就分手", top: 0)


    struct Slow: EmotionAnalyzer {
        var name = "slow"
        func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
            try await Task.sleep(for: .seconds(5))
            return EmotionReport(message: latest, emotion: "生气", intensity: 3, flags: ["manipulation": 1], engine: name, latencyMs: 5000)
        }
    }



    func testEveryRequiredMoneyItemMentionsMoney() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        var checked = 0
        for file in ["eval/crosscultural.jsonl", "eval/crosscultural.holdout.jsonl", "eval/crosscultural.holdout2.jsonl", "train/pool_eval.jsonl"] {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for line in text.split(whereSeparator: \.isNewline) {
                let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                guard let flags = (item["expect"] as? [String: Any])?["flags"] as? [String], flags.contains("asks_money"),
                      let message = item["text"] as? String else { continue }
                XCTAssertTrue(MoneyNet.mentionsMoney(message), "\(file): \(message)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 20)
    }
}
