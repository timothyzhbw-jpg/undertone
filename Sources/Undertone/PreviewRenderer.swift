import AppKit
import UndertoneCore
import SwiftUI

/// 用示例数据把面板渲染成 PNG：`Undertone --render-previews <目录>`。不截屏、不读任何聊天。
@MainActor
enum PreviewRenderer {
    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings()
        // 设置会写进用户的 UserDefaults：渲染完恢复原样
        let saved = settings.relationship
        defer { settings.relationship = saved }
        settings.relationship = "客户"
        // 用临时文件里的示例记忆，绝不碰用户真实的记忆。
        let memoryURL = FileManager.default.temporaryDirectory.appending(path: "undertone-preview-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: memoryURL) }
        let memory = ContactMemoryStore(fileURL: memoryURL)
        Sample.fillMemory(memory)
        for (name, setup) in scenarios {
            for dark in [false, true] {
                let monitor = Monitor(settings: settings, memory: memory)
                setup(monitor)
                let url = directory.appending(path: "\(name)\(dark ? "-dark" : "").png")
                try render(PanelView(monitor: monitor, settings: settings, scrolls: false), dark: dark, to: url)
                print(url.path)
            }
        }
        for dark in [false, true] {
            let monitor = Monitor(settings: settings, memory: memory)
            monitor.loadPreview(status: .paused, reports: [Sample.stalling])
            let sample = "John: Thanks for sending the quote over.\nMe: Sure! Any questions so far?\nJohn — Today at 9:40 PM\nWe'll review it internally and get back to you."
            let url = directory.appending(path: "manual\(dark ? "-dark" : "").png")
            try render(VStack(spacing: 12) {
                ManualView(monitor: monitor, settings: settings, transcript: .constant(sample), editable: false)
                ReportView(report: Sample.stalling, isLatest: true, analyzing: false)
            }.padding(14), dark: dark, to: url)
            print(url.path)
        }
        for dark in [false, true] {
            let monitor = Monitor(settings: settings, memory: memory)
            let url = directory.appending(path: "memory-sheet\(dark ? "-dark" : "").png")
            try render(MemoryView(monitor: monitor, settings: settings, contact: Sample.contact, scrolls: false), dark: dark, to: url, width: 420)
            print(url.path)
        }
    }

    private static func render(_ view: some View, dark: Bool, to url: URL, width: CGFloat = 372) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let content = view
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            image = renderer.cgImage
        }
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    private static var scenarios: [(String, (Monitor) -> Void)] { [
        ("report", { $0.loadPreview(status: .watching, reports: [Sample.tradeNegotiation, Sample.workSoftNo, Sample.professorNudge]) }),
        ("memory", { $0.loadPreview(status: .watching, reports: [Sample.interestWithMemory, Sample.tradeNegotiation]) }),
        ("scam", { $0.loadPreview(status: .watching, reports: [Sample.tradeScam]) }),
        ("draft", { $0.loadPreview(status: .watching, reports: [Sample.tradeNegotiation], draftReview: Sample.draftTooBlunt) }),
        ("safety", { $0.loadPreview(status: .watching, reports: [Sample.crisis]) }),
        ("analyzing", { $0.loadPreview(status: .watching, reports: [Sample.workSoftNo], analyzing: true) }),
        ("voice", { $0.loadPreview(status: .watching, reports: [Sample.workSoftNo], pendingVoice: 6) }),
        ("onboarding", { $0.loadPreview(status: .noWindow(chosen: false), reports: [], windowName: "") }),
        ("error", { $0.loadPreview(status: .watching, reports: [],
                                   error: L("连不上分析引擎（本地大模型）。请先在终端运行 ollama serve。",
                                            "Can't reach the analysis engine (local model). Run ollama serve in Terminal first.")) }),
    ] }
}

/// 示例分析结果（虚构的对话）：对方的英文原话，中文解释。情绪、回应方式等用中文规范值，界面按语言显示。
enum Sample {
    static var llm: String { L("本地大模型 · qwen3.5:4b", "Local model · qwen3.5:4b") }
    static let contact = "John"

    static func report(_ text: String, reading: String, emotion: String = "平静", intensity: Double = 1, flags: [EmotionFlag: Double] = [:],
                       response: String, literal: String, why: String, meaning: String, confidence: Double,
                       reply: String, gloss: String, contact: String = Sample.contact, minutesAgo: Double = 0) -> EmotionReport {
        var r = EmotionReport(message: ChatMessage(speaker: .them, text: text, top: 0.8), emotion: emotion, intensity: intensity,
                              flags: Dictionary(uniqueKeysWithValues: flags.map { ($0.key.rawValue, $0.value) }),
                              bestResponse: response, target: "这件事", literal: literal, realMeaning: meaning, suggestedReply: reply,
                              reading: reading, confidence: confidence, cultureNote: why, replyGloss: gloss,
                              contact: contact, engine: llm, latencyMs: 3900)
        r.date = Date(timeIntervalSinceNow: -minutesAgo * 60)
        return r
    }

    static var tradeNegotiation: EmotionReport { report(
        "Hmm, that's a bit higher than what we're seeing from other suppliers.", reading: "在压价", response: "解释澄清",
        literal: L("嗯，这比我们从别的供应商那里看到的要高一点。", "That's a little more than other suppliers are quoting."),
        why: L("拿别家比价是常见的压价说法，未必真有更低的报价，但说明价格是对方现在最大的顾虑。",
               "Comparing you to other suppliers is a standard way to push on price. They may not have a lower quote, but price is their main concern."),
        meaning: L("想让你降价，或者至少给出贵的理由。", "They want a discount, or at least a reason for the price."), confidence: 3,
        reply: "I understand. Could you share the target price you have in mind? With a larger volume, we may have some room.",
        gloss: L("理解。能告诉我你们的目标价吗？如果数量更大，我们也许还有空间。", "Ask for their target price and hint at volume pricing.")) }

    static var workSoftNo: EmotionReport { report(
        "That's an interesting idea. Let's keep it in mind for later.", reading: "委婉拒绝", response: "正常聊天",
        literal: L("这个想法挺有意思。我们以后再考虑。", "Nice idea, maybe later."),
        why: L("「interesting idea」加上「keep it in mind for later」在职场里通常是礼貌地否决。",
               "\"Interesting idea\" plus \"keep it in mind for later\" is usually a polite no at work."),
        meaning: L("现在不会这么做，先别推了。", "It's not happening now — don't push."), confidence: 2,
        reply: "Sounds good. If it becomes relevant, I'm happy to write up a short proposal.",
        gloss: L("好的。以后如果用得上，我可以写一个简短的方案。", "Accept gracefully and offer a proposal later."), minutesAgo: 4) }

    static var professorNudge: EmotionReport { report(
        "Hi, just checking in, I haven't received your draft yet.", reading: "在催你", response: "真诚道歉",
        literal: L("你好，问一下，我还没收到你的初稿。", "Hi, I haven't received your draft."),
        why: L("「just checking in」说得很客气，但老师主动来问，说明已经过了你答应的时间。",
               "\"Just checking in\" is polite, but a professor asking means you're past the time you promised."),
        meaning: L("你说好要交的，现在该交了。", "You said you'd send it — it's due now."), confidence: 3,
        reply: "Hi Professor Lee, I'm sorry for the delay. I'll send the draft by tomorrow noon.",
        gloss: L("李老师您好，抱歉拖晚了。我明天中午前把初稿发给您。", "Apologize and give a firm time."),
        contact: "Prof. Lee", minutesAgo: 30) }

    static var interestWithMemory: EmotionReport {
        var r = report(
            "Thanks! Can you send me the spec sheet and your lead time for 10,000 pcs? We'd need them by the end of March.",
            reading: "有兴趣", emotion: "开心", response: "跟进推进",
            literal: L("谢谢！能把规格书发我吗？还有 1 万件的交期是多久？我们需要在 3 月底前拿到。",
                       "Send the spec sheet and lead time for 10,000 pieces; needed by end of March."),
            why: L("主动要规格书、问大数量的交期并给出到货时间，是很明确的采购信号。",
                   "Asking for specs and lead time on a big quantity with a deadline is a clear buying signal."),
            meaning: L("对方在认真考虑下单，想确认能不能赶上 3 月底。", "They're seriously considering an order and need it by end of March."),
            confidence: 3,
            reply: "Of course, John. I'll send the spec sheet today and confirm the lead time for 10,000 pcs with our factory by tomorrow.",
            gloss: L("当然。我今天就把规格书发你，明天前和工厂确认 1 万件的交期再回复你。", "Send specs today; confirm lead time tomorrow."))
        r.memoryNote = L("John 需要 1 万件，3 月底前到货", "John needs 10,000 pcs by end of March")
        return r
    }

    static var tradeScam: EmotionReport { report(
        "Please note our bank account has changed due to an audit. Kindly remit the balance to the new account below.",
        reading: "可疑", flags: [.asksMoney: 1], response: "核实身份",
        literal: L("请注意，由于审计，我们的银行账户变了。请把尾款汇到下面的新账户。", "Our bank account changed; pay the balance to the new one."),
        why: L("以审计等理由临时更改收款账户，是外贸里最常见的诈骗手法：骗子盗用或仿冒对方的邮箱和账号。",
               "A sudden \"new bank account\" is the most common trade scam: someone has hijacked or spoofed their email."),
        meaning: L("可能不是对方本人，有人想骗走这笔货款。", "This may not be them — someone may be trying to steal the payment."), confidence: 3,
        reply: "Thanks for letting us know. Before we update anything, I'll call you at your usual number to confirm the change.",
        gloss: L("谢谢告知。在改任何信息之前，我会打你平时的电话确认一下。", "Don't pay yet — confirm by phone first.")) }

    static var stalling: EmotionReport { report(
        "We'll review it internally and get back to you.", reading: "还没决定", response: "跟进推进",
        literal: L("我们内部评估一下再回复你。", "We'll review it and get back to you."),
        why: L("询价后的标准客气回复，既没答应也没拒绝；没有追问数量、交期，通常说明还在比价。",
               "A standard polite reply after a quote: no yes, no no. Without follow-up questions it usually means they're comparing suppliers."),
        meaning: L("收到了，还在和别家比较，暂时不会决定。", "Received; still comparing, no decision yet."), confidence: 2,
        reply: "Sounds good, John. If samples would help your review, just let me know. Is there a date you're aiming to decide by?",
        gloss: L("好的。如果需要样品帮助评估，随时告诉我。你们大概打算什么时候定下来？", "Offer samples and ask for their decision date.")) }

    static var draftTooBlunt: DraftReview { DraftReview(
        draft: "No, this price is impossible for us.",
        landsAs: L("拒绝得很硬，像把谈判的门关上了。", "A hard no — it sounds like you're ending the negotiation."),
        verdict: "太生硬",
        issues: L("「impossible」太绝对，商务谈判里通常先表示理解，再说明做不到。",
                  "\"Impossible\" is too absolute. In a negotiation, acknowledge their ask first, then say what you can't do."),
        rewrite: "I'm afraid we can't go that low. Is there any flexibility on your side?",
        rewriteGloss: L("恐怕我们做不到那么低。你们那边有没有调整的空间？", "Polite no, and keeps the door open."),
        engine: llm, latencyMs: 3100) }

    /// 安全底线：轻生信号照常提醒（不对外宣传，但不能没有）。
    static var crisis: EmotionReport { report(
        "honestly everyone would be better off if I wasn't around", reading: "字面意思", emotion: "难过", intensity: 3,
        flags: [.needsComfort: 1, .selfHarm: 0.6], response: "寻求帮助",
        literal: L("说实话，如果我不在了，大家都会过得更好。", "Everyone would be better off without me."),
        why: L("这不是英语里的日常夸张，而是在说自己是负担、不想活下去的念头，要认真对待。",
               "This isn't everyday exaggeration — it's a thought of being a burden and not wanting to live. Take it seriously."),
        meaning: L("对方可能有轻生的念头，非常需要有人陪。", "They may be thinking about ending their life and need someone with them."), confidence: 3,
        reply: "I'm really glad you told me. Are you safe right now? I'm here, and I want to hear what's going on.",
        gloss: L("谢谢你愿意告诉我。你现在安全吗？我在，想听听发生了什么。", "Ask if they're safe and stay with them."),
        contact: "Alex") }

    /// 预览用的示例记忆（虚构的客户）。
    static func fillMemory(_ store: ContactMemoryStore) {
        store.update(contact) { memory in
            memory.relationship = "客户"
            memory.notes = [
                .init(text: L("美国进口商，做户外家具", "US importer, outdoor furniture"), source: .user, date: Date(timeIntervalSinceNow: -20 * 86_400)),
                .init(text: L("习惯邮件沟通，周五下午不回消息", "Prefers email; doesn't reply Friday afternoons"), source: .user,
                      date: Date(timeIntervalSinceNow: -9 * 86_400)),
                .init(text: L("第一单要 5,000 件，3 月底前到货", "First order: 5,000 pcs by end of March"), source: .ai,
                      date: Date(timeIntervalSinceNow: -2 * 86_400)),
            ]
            let history: [(String, String, [String: Double], Double)] = [
                ("Thanks for the catalog, very impressive.", "开心", [:], 12),
                ("Your price is not competitive.", "平静", [:], 6),
                ("We'll review it internally and get back to you.", "平静", [:], 3),
                ("Any update on the samples?", "焦虑", [:], 1),
            ]
            for (text, emotion, flags, days) in history {
                var r = EmotionReport(message: ChatMessage(speaker: .them, text: text, top: 0.8), emotion: emotion, intensity: 1,
                                      flags: flags, bestResponse: "正常聊天", engine: llm, latencyMs: 3000)
                r.date = Date(timeIntervalSinceNow: -days * 86_400)
                memory.record(r)
            }
        }
    }
}
