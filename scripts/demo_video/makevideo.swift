// 把录好的原始视频做成成片：1920×1080（PRESET 环境变量可改），开头标题卡、结尾收尾卡，底部字幕，旁白用 macOS 的 say 合成。
// 旁白和原始视频里的声音放在同一条音轨上（mp4 里多条音轨不会混音，YouTube 只播第一条）；前一句没说完就顺延。
// 用法：swiftc -O -parse-as-library makevideo.swift -o makevideo && ./makevideo plan.json
// voice 写 say 的声音名，或 Siri 自然声音的 ID（com.apple.siri.natural.…，由 tts.swift 合成，要先在系统设置里下载）。
import AppKit
import AVFoundation
import QuartzCore

struct Cue: Decodable {
    let at: Double          // 在原始视频里的第几秒开始说
    let say: String         // 旁白
    let caption: String?    // 字幕（不写就用旁白）
}

struct Plan: Decodable {
    let video: String
    let output: String
    let voice: String
    let rate: Int
    let introSeconds: Double
    let outroSeconds: Double
    let introTitle: String
    let introSubtitle: String
    let introSay: String
    let outroTitle: String
    let outroSubtitle: String
    let outroSay: String
    let cues: [Cue]
    let rawAudio: [[Double]]?   // 原始视频里要保留声音的片段 [开始, 结束]（秒）
}

let size = CGSize(width: 1920, height: 1080)
let ground = CGColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1)
let ink = CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
let brand = CGColor(red: 0.30, green: 0.40, blue: 0.90, alpha: 1)

/// 旁白音频：voice 是 Siri 自然声音的 ID（com.apple.…）时用同目录的 tts.swift 一次合成好，否则用 say。
func synthesize(_ texts: [String], voice: String, rate: Int, in directory: URL) throws -> [URL] {
    let urls = texts.indices.map { directory.appending(path: "\($0).caf") }
    if voice.hasPrefix("com.apple.") {
        // Siri 声音只有从终端直接运行时才看得到，由本程序启动的子进程看不到：先写好任务，让人在终端里合成，合成过的不再重做
        let jobs = zip(texts, urls).map { ["text": $0, "out": $1.path, "voice": voice] }
        let list = directory.appending(path: "jobs.json")
        let data = try JSONSerialization.data(withJSONObject: jobs, options: .sortedKeys)
        let done = (try? Data(contentsOf: list)) == data && urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        if !done {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            try data.write(to: list)
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "tts.swift")
            print("先在终端里合成旁白，再运行一次：\nswift \(script.lastPathComponent)（和 makevideo.swift 在同一目录） \(voice) \(list.path)")
            exit(2)
        }
    } else {
        for (text, url) in zip(texts, urls) { try run("/usr/bin/say", ["-v", voice, "-r", String(rate), "--file-format=caff", "-o", url.path, text]) }
    }
    return urls
}

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("\(tool) 失败") }
}

func duration(of url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.fileFormat.sampleRate
}

/// 文字先画成图片再贴到图层上：macOS 上 CATextLayer 在视频合成里画不出字。
func textLayer(_ text: String, size fontSize: CGFloat, weight: NSFont.Weight, color: CGColor, frame: CGRect) -> CALayer {
    let scale: CGFloat = 2
    let context = CGContext(data: nil, width: Int(frame.width * scale), height: Int(frame.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor(cgColor: color) ?? .black,
        .paragraphStyle: paragraph,
    ])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let bounds = attributed.boundingRect(with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
    attributed.draw(with: CGRect(x: 0, y: (frame.height - bounds.height) / 2, width: frame.width, height: bounds.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    let layer = CALayer()
    layer.frame = frame
    layer.contents = context.makeImage()
    layer.contentsGravity = .resize
    return layer
}

/// 只在 [start, end) 这段时间里显示。导出时按帧取值，动画不能在「播完」后被移除。
func show(_ layer: CALayer, from start: Double, to end: Double) {
    layer.opacity = 0
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = 1
    animation.beginTime = AVCoreAnimationBeginTimeAtZero + start
    animation.duration = end - start
    animation.isRemovedOnCompletion = false
    layer.add(animation, forKey: nil)
}

@main
struct MakeVideo {
    static func main() async throws {
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let work = URL(fileURLWithPath: plan.output).deletingLastPathComponent().appending(path: "narration")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let raw = AVURLAsset(url: URL(fileURLWithPath: plan.video))
        guard let rawVideo = try await raw.loadTracks(withMediaType: .video).first else { fatalError("原始视频里没有画面") }
        let rawDuration = try await raw.load(.duration)
        let natural = try await rawVideo.load(.naturalSize)
        let intro = CMTime(seconds: plan.introSeconds, preferredTimescale: 600)
        let outro = CMTime(seconds: plan.outroSeconds, preferredTimescale: 600)

        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        video.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: intro))
        // 屏幕不变时 ScreenCaptureKit 不出新帧，画面轨可能比声音短：把最后一帧拉长到原始视频结束
        let videoEnd = try await rawVideo.load(.timeRange).end
        try video.insertTimeRange(CMTimeRange(start: .zero, end: min(videoEnd, rawDuration)), of: rawVideo, at: intro)
        if videoEnd < rawDuration {
            let frame = CMTime(value: 1, timescale: 30)
            video.scaleTimeRange(CMTimeRange(start: intro + videoEnd - frame, duration: frame), toDuration: frame + rawDuration - videoEnd)
        }

        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let rawAudio = try await raw.loadTracks(withMediaType: .audio).first
        let speech = try synthesize([plan.introSay] + plan.cues.map(\.say) + [plan.outroSay], voice: plan.voice, rate: plan.rate, in: work)
        enum Piece { case speech(index: Int, text: String, caption: String?), original(Double, Double) }
        var pieces: [(start: Double, piece: Piece)] = [(0.6, .speech(index: 0, text: plan.introSay, caption: nil))]
        for (i, cue) in plan.cues.enumerated() {
            pieces.append((plan.introSeconds + cue.at, .speech(index: i + 1, text: cue.say, caption: cue.caption ?? cue.say)))
        }
        pieces.append((plan.introSeconds + rawDuration.seconds + 0.6, .speech(index: plan.cues.count + 1, text: plan.outroSay, caption: nil)))
        if rawAudio != nil {
            for range in plan.rawAudio ?? [] { pieces.append((plan.introSeconds + range[0], .original(range[0], range[1]))) }
        }
        pieces.sort { $0.start < $1.start }
        var spans: [(start: Double, end: Double, caption: String?)] = []
        var free = 0.0
        for item in pieces {
            switch item.piece {
            case let .original(from, to):
                if free > item.start { fatalError(String(format: "旁白盖住了原声（原声从 %.1f 秒开始，旁白到 %.1f 秒）", item.start, free)) }
                try audio.insertTimeRange(CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600)),
                                          of: rawAudio!, at: CMTime(seconds: item.start, preferredTimescale: 600))
                free = item.start + (to - from)
            case let .speech(index, text, caption):
                let url = speech[index]
                let duration = try duration(of: url)
                let start = max(item.start, free + 0.25)
                if start > item.start + 0.05 { print(String(format: "第 %d 句顺延了 %.1f 秒", index, start - item.start)) }
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let length = try await asset.load(.duration)
                try audio.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: CMTime(seconds: start, preferredTimescale: 600))
                spans.append((start, start + duration, caption))
                free = start + duration
            }
        }
        // 收尾卡至少 outroSeconds，旁白没说完就延长到说完再停 1 秒；画面必须盖住整个时长，否则合成会失败
        let total = CMTimeMaximum(intro + rawDuration + outro, CMTime(seconds: free + 1.0, preferredTimescale: 600))
        video.insertEmptyTimeRange(CMTimeRange(start: intro + rawDuration, duration: total - (intro + rawDuration)))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        instruction.backgroundColor = ground
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        let box = CGSize(width: size.width - 120, height: size.height - 40 - 170)
        let scale = min(box.width / natural.width, box.height / natural.height)
        let x = (size.width - natural.width * scale) / 2
        layerInstruction.setTransform(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: x, y: 40)), at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true
        parent.backgroundColor = ground
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        for span in spans {
            guard let caption = span.caption else { continue }
            let pill = CALayer()
            pill.frame = CGRect(x: 160, y: size.height - 150, width: size.width - 320, height: 112)
            pill.backgroundColor = CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 0.86)
            pill.cornerRadius = 20
            pill.addSublayer(textLayer(caption, size: 34, weight: .medium, color: CGColor(gray: 1, alpha: 1),
                                       frame: CGRect(x: 36, y: 14, width: pill.frame.width - 72, height: 90)))
            show(pill, from: span.start, to: max(span.end, span.start + 2.5))
            parent.addSublayer(pill)
        }

        func card(title: String, subtitle: String, from start: Double, to end: Double) {
            let layer = CALayer()
            layer.frame = parent.frame
            layer.backgroundColor = ground
            let name = textLayer("Undertone", size: 132, weight: .bold, color: brand, frame: CGRect(x: 0, y: 330, width: size.width, height: 170))
            let line1 = textLayer(title, size: 54, weight: .semibold, color: ink, frame: CGRect(x: 160, y: 520, width: size.width - 320, height: 80))
            let line2 = textLayer(subtitle, size: 34, weight: .regular, color: CGColor(red: 0.38, green: 0.41, blue: 0.46, alpha: 1),
                                  frame: CGRect(x: 160, y: 615, width: size.width - 320, height: 120))
            [name, line1, line2].forEach(layer.addSublayer)
            show(layer, from: start, to: end)
            parent.addSublayer(layer)
        }
        card(title: plan.introTitle, subtitle: plan.introSubtitle, from: 0, to: plan.introSeconds)
        card(title: plan.outroTitle, subtitle: plan.outroSubtitle, from: (intro + rawDuration).seconds, to: total.seconds + 1)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        let output = URL(fileURLWithPath: plan.output)
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: ProcessInfo.processInfo.environment["PRESET"] ?? AVAssetExportPreset1920x1080)
        else { fatalError("导出失败") }
        export.videoComposition = videoComposition
        try await export.export(to: output, as: .mp4)
        print(String(format: "完成：%@，%.1f 秒", output.path, total.seconds))
    }
}
