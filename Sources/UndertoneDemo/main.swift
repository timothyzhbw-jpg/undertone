// 演示聊天窗口：没有聊天软件、或不想用真实聊天测试时，用它来试 Undertone。
// 运行：swift run UndertoneDemo（每 DEMO_INTERVAL 秒收到一条新消息，默认 15 秒）
// 对话是英文的（外国买家）；--language en|zh 只影响窗口里的日期等少量文字
import AppKit
import AVFoundation
import SwiftUI

/// 播放语音消息：先把这条语音的内容合成成音频，再由演示程序自己播放。
/// 不直接用 speak()：那样声音可能由系统的朗读服务播放，Undertone 只录这个程序的声音时会录不到。
@MainActor
enum VoicePlayer {
    static let synthesizer = AVSpeechSynthesizer()
    static let engine = AVAudioEngine()
    static let player = AVAudioPlayerNode()
    static var connected = false

    final class Collected: @unchecked Sendable { var buffers: [AVAudioPCMBuffer] = [] }

    static func play(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let collected = Collected()
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                collected.buffers.append(pcm)
            } else {
                let buffers = collected.buffers   // 长度为 0 的缓冲表示合成完了
                Task { @MainActor in schedule(buffers) }
            }
        }
    }

    private static func schedule(_ buffers: [AVAudioPCMBuffer]) {
        guard let format = buffers.first?.format else { return }
        if !connected {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connected = true
        }
        if !engine.isRunning { try? engine.start() }
        player.stop()
        for buffer in buffers { player.scheduleBuffer(buffer) }
        player.play()
    }
}

/// 和 Undertone 一样的规则：--language > UNDERTONE_LANGUAGE > 系统语言。
let english: Bool = {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--language"), i + 1 < args.count { return args[i + 1] == "en" }
    if let env = ProcessInfo.processInfo.environment["UNDERTONE_LANGUAGE"] { return env == "en" }
    return !(Locale.preferredLanguages.first ?? "").hasPrefix("zh")
}()

struct Line: Identifiable {
    enum Kind {
        case text
        /// 语音：秒数；转文字之后才有 transcript
        case voice(Int)
        /// 表情包：画一个卡通脸，下面配字
        case sticker
    }

    var id = UUID()
    let fromMe: Bool
    let text: String
    var kind = Kind.text
    var transcript: String?
}

/// 演示对话：外国买家 John 用英文和你谈一笔订单（虚构）。Undertone 读的是英文消息，所以不分界面语言。
let opening = [
    Line(fromMe: true, text: "Hi John, attached is our quotation for 5,000 units. Let me know if you have any questions."),
    Line(fromMe: false, text: "Thanks, got it."),
]

/// 每一步：追加几条消息；或者把最后一条语音「转文字」（模拟在聊天软件里把语音转成文字）。
enum Step {
    case add([Line])
    case transcribe(String)
}

let script: [Step] = [
    .add([Line(fromMe: false, text: "Honestly, your price is a bit higher than the other quotes we got.")]),
    .add([Line(fromMe: true, text: "We can do 3% off if the order goes up to 10,000 units."),
          Line(fromMe: false, text: "Interesting. Let me run this by my team and circle back.")]),
    .add([Line(fromMe: false, text: "Quick question, could you send three samples to our Chicago office this week?", kind: .voice(6))]),
    .transcribe("Quick question, could you send three samples to our Chicago office this week?"),
    .add([Line(fromMe: true, text: "Sure, the samples will ship on Friday."), Line(fromMe: false, text: "deal!", kind: .sticker)]),
    .add([Line(fromMe: false, text: "Great. Our buyer meeting is on March 3rd, so we'd need them before then.")]),
    .add([Line(fromMe: false, text: "Just following up on the revised invoice, our finance team is waiting on it.")]),
    .add([Line(fromMe: false, text: "Please note our bank account has changed due to an audit. Kindly send the deposit to the new account below.")]),
]

@MainActor
final class Conversation: ObservableObject {
    @Published var lines = opening
    private var step = 0

    func advance() {
        guard step < script.count else { return }
        switch script[step] {
        case .add(let new):
            lines += new
            // DEMO_AUTOPLAY_VOICE=1：收到语音两秒后自动播放（测试和录演示时不用点）
            if ProcessInfo.processInfo.environment["DEMO_AUTOPLAY_VOICE"] == "1",
               let voice = new.first(where: { if case .voice = $0.kind { true } else { false } }) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    VoicePlayer.play(voice.text)
                }
            }
        case .transcribe(let text):
            // DEMO_SKIP_TRANSCRIBE=1：聊天窗口不自己转文字（演示 Undertone 用 deAPI 听语音时用）
            if ProcessInfo.processInfo.environment["DEMO_SKIP_TRANSCRIBE"] == "1" { break }
            if let index = lines.lastIndex(where: { if case .voice = $0.kind { true } else { false } }) {
                lines[index].transcript = text
            }
        }
        step += 1
    }
}

struct ChatView: View {
    @ObservedObject var conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            Text("John Miller").font(.system(size: 15, weight: .medium)).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        Text(english ? "Yesterday 9:05 PM" : "昨天 21:05").font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(conversation.lines) { Bubble(line: $0).id($0.id) }
                    }
                    .padding(16)
                }
                .onChange(of: conversation.lines.count) {
                    if let last = conversation.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(width: 520, height: 640)
        .background(Color(red: 0.93, green: 0.93, blue: 0.93))
    }
}

struct Bubble: View {
    let line: Line

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if line.fromMe { Spacer(minLength: 60) } else { avatar(.orange) }
            VStack(alignment: line.fromMe ? .trailing : .leading, spacing: 4) {
                content
                if let transcript = line.transcript {
                    // 转文字的结果：贴在语音下面的浅色框
                    Text(transcript)
                        .font(.system(size: 14))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if line.fromMe { avatar(.blue) } else { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder private var content: some View {
        let fill = line.fromMe ? Color(red: 0.58, green: 0.93, blue: 0.41) : Color.white
        switch line.kind {
        case .text:
            Text(line.text)
                .font(.system(size: 14))
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(fill, in: RoundedRectangle(cornerRadius: 5))
        case .voice(let seconds):
            HStack(spacing: 6) {
                Image(systemName: "wave.3.right").font(.system(size: 14))
                Text("\(seconds)\"").font(.system(size: 14))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: 70 + CGFloat(seconds) * 3, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { VoicePlayer.play(line.text) }   // 点语音气泡 = 播放
        case .sticker:
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color(red: 1, green: 0.75, blue: 0.3)).frame(width: 80, height: 80)
                    HStack(spacing: 18) { Circle().fill(.black).frame(width: 9); Circle().fill(.black).frame(width: 9) }.offset(y: -8)
                    Capsule().fill(Color(red: 0.8, green: 0.2, blue: 0.2)).frame(width: 26, height: 7).offset(y: 16)
                }
                Text(line.text).font(.system(size: 22, weight: .black)).foregroundStyle(Color(red: 0.9, green: 0.2, blue: 0.3))
            }
            .frame(width: 110, height: 125)
        }
    }

    private func avatar(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.7)).frame(width: 36, height: 36)
    }
}

@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate {
    let conversation = Conversation()
    var window: NSWindow?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 520, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = english ? "Undertone Demo Chat" : "Undertone 演示聊天"
        window.contentView = NSHostingView(rootView: ChatView(conversation: conversation))
        // DEMO_ON_TOP=1（录演示视频用）：跟到当前桌面空间、浮在别的应用的全屏画面之上，保证录得到
        if ProcessInfo.processInfo.environment["DEMO_ON_TOP"] == "1" {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        NSApp.activate()
        print("UndertoneDemo windowID=\(window.windowNumber)")
        fflush(stdout)
        let interval = Double(ProcessInfo.processInfo.environment["DEMO_INTERVAL"] ?? "") ?? 15
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in self.conversation.advance() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = DemoDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
