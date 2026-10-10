// 用 macOS 的 Siri 自然声音合成旁白（say 命令用不了这些声音）。要用解释执行：swift tts.swift 声音ID 任务.json
// 编译成独立程序后看不到 Siri 声音。任务.json：[{"text": "…", "out": "0.caf"}, …]
import AVFoundation

struct Job: Decodable { let text: String; let out: String }   // 还可能有 voice 字段，用来判断要不要重新合成
let args = CommandLine.arguments
guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == args[1] }) else { fatalError("没有这个声音：\(args[1])") }
let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let synthesizer = AVSpeechSynthesizer()
for job in jobs {
    let utterance = AVSpeechUtterance(string: job.text)
    utterance.voice = voice
    var file: AVAudioFile?
    var finished = false
    // 回调在主线程上：不能用信号量干等，要转主 run loop
    synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { finished = true; return }
        if file == nil {
            file = try? AVAudioFile(forWriting: URL(fileURLWithPath: job.out), settings: pcm.format.settings,
                                    commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
        }
        try? file?.write(from: pcm)
    }
    let deadline = Date().addingTimeInterval(60)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard finished, file != nil else { fatalError("合成失败：\(job.text)") }
}
print("合成了 \(jobs.count) 句")
