// 把成片压到给定码率（上传有大小限制时用）：./reencode 输入.mp4 输出.mp4 码率（bit/s）
import AVFoundation
let input = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let output = URL(fileURLWithPath: CommandLine.arguments[2]); try? FileManager.default.removeItem(at: output)
let bitrate = Int(CommandLine.arguments[3])!
let videoTrack = try await input.loadTracks(withMediaType: .video).first!
let audioTrack = try await input.loadTracks(withMediaType: .audio).first
let size = try await videoTrack.load(.naturalSize)
let reader = try AVAssetReader(asset: input)
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(videoOut)
let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoMaxKeyFrameIntervalKey: 120]])
writer.add(videoIn)
var audioOut: AVAssetReaderTrackOutput?
var audioIn: AVAssetWriterInput?
if let audioTrack {
    let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    reader.add(out); audioOut = out
    let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                                                                   AVSampleRateKey: 22050, AVEncoderBitRateKey: 48000])
    writer.add(a); audioIn = a
}
reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
// 画面和声音要同时喂：写入器按时间交错，只喂一路时另一路会一直等，整个导出卡死
final class Pump: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput, input: AVAssetWriterInput
    init(_ output: AVAssetReaderTrackOutput, _ input: AVAssetWriterInput) { self.output = output; self.input = input }
    func run(_ group: DispatchGroup) {
        group.enter()
        let queue = DispatchQueue(label: "pump")
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else { input.markAsFinished(); group.leave(); return }
                input.append(sample)
            }
        }
    }
}
let group = DispatchGroup()
let pumps = [Pump(videoOut, videoIn)] + (audioOut.flatMap { out in audioIn.map { Pump(out, $0) } }.map { [$0] } ?? [])
pumps.forEach { $0.run(group) }
await withCheckedContinuation { continuation in group.notify(queue: .main) { continuation.resume() } }
await writer.finishWriting()
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print(String(format: "完成 %.1f MB", Double(bytes) / 1_048_576))
