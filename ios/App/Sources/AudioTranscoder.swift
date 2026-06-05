import Foundation
import AVFoundation

/// 把任意 AVFoundation 可解码的音频(重点:语音备忘录的 **.m4a / AAC-LC**)转成
/// **16kHz 单声道 16-bit PCM WAV** —— 豆包录音文件识别接受的格式(它只认 pcm/wav/mp3/ogg-opus/opus,
/// **不认 m4a/aac**,所以进豆包前必须转这一步)。
///
/// 纯系统能力(AVAudioFile + AVAudioConverter),无第三方库、无服务端,契合「零增量」。
/// 采样率非整数倍(32k/44.1k/48k → 16k)用 converter 的 **pull(inputBlock)** 模式重采样。
///
/// 体积提示:16k/mono/16bit ≈ 32KB/s ≈ 50 分钟/100MB。超长会议后续再做分段;此处只负责单文件转码。
enum AudioTranscoder {

    static let targetRate: Double = 16000

    enum TranscodeError: Error, CustomStringConvertible {
        case openFailed(String)
        case formatFailed
        case converterFailed
        var description: String {
            switch self {
            case .openFailed(let m): return "打开输入音频失败: \(m)"
            case .formatFailed:      return "构造 16k/mono PCM 格式失败"
            case .converterFailed:   return "创建 AVAudioConverter 失败"
            }
        }
    }

    /// 转码 `input` → `output`(.wav)。返回输出音频时长(秒)。会覆盖已存在的 output。
    /// 抛错即失败(调用方回退/提示)。同步执行 —— 大文件请放后台队列调用。
    @discardableResult
    static func toWav16kMono(input: URL, output: URL) throws -> Double {
        let inFile: AVAudioFile
        do { inFile = try AVAudioFile(forReading: input) }
        catch { throw TranscodeError.openFailed(error.localizedDescription) }
        let inFormat = inFile.processingFormat                       // 通常 float32,源采样率/声道

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: targetRate,
                                            channels: 1, interleaved: true) else {
            throw TranscodeError.formatFailed
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscodeError.converterFailed
        }

        try? FileManager.default.removeItem(at: output)
        // 扩展名 .wav + LinearPCM settings → AVAudioFile 写出标准 WAVE 容器。
        let outFile = try AVAudioFile(forWriting: output,
                                      settings: outFormat.settings,
                                      commonFormat: .pcmFormatInt16,
                                      interleaved: true)

        let readChunk: AVAudioFrameCount = 16384
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readChunk) else {
            throw TranscodeError.formatFailed
        }

        var reachedEnd = false
        var totalOut: AVAudioFramePosition = 0

        while true {
            let outCap = AVAudioFrameCount(Double(readChunk) * targetRate / inFormat.sampleRate) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
                throw TranscodeError.formatFailed
            }

            var convErr: NSError?
            let status = converter.convert(to: outBuffer, error: &convErr) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inBuffer.frameLength = 0
                    try inFile.read(into: inBuffer, frameCount: readChunk)
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {            // 读到文件尾
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }

            if let convErr { throw convErr }
            if outBuffer.frameLength > 0 {
                try outFile.write(from: outBuffer)
                totalOut += AVAudioFramePosition(outBuffer.frameLength)
            }
            if status == .endOfStream || status == .error { break }
            if reachedEnd && outBuffer.frameLength == 0 { break }
        }

        return Double(totalOut) / targetRate
    }

    /// 转码 + **按时长分段**:每段 ≤ `maxSeconds` 的 16k/mono WAV 写进 `outputDir`,返回有序段 URL。
    /// 长录音(80min ≈ 160MB)单次 base64 POST 易因超 100MB 限制 / 网络抖动失败 → 分段后每段独立上传、
    /// 可逐段重试(issue #19)。短录音返回单段。切段落在整块边界(不拆句),段长 ≈ maxSeconds ± 一个读块。
    static func toWav16kMonoSegments(input: URL, outputDir: URL, maxSeconds: Double = 600) throws -> [URL] {
        let inFile: AVAudioFile
        do { inFile = try AVAudioFile(forReading: input) }
        catch { throw TranscodeError.openFailed(error.localizedDescription) }
        let inFormat = inFile.processingFormat

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetRate,
                                            channels: 1, interleaved: true) else { throw TranscodeError.formatFailed }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw TranscodeError.converterFailed }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let readChunk: AVAudioFrameCount = 16384
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readChunk) else { throw TranscodeError.formatFailed }
        let maxFrames = AVAudioFramePosition(maxSeconds * targetRate)

        var segments: [URL] = []
        var outFile: AVAudioFile?
        var segFrames: AVAudioFramePosition = 0
        func openSegment() throws {
            let url = outputDir.appendingPathComponent("seg-\(segments.count).wav")
            try? FileManager.default.removeItem(at: url)
            outFile = try AVAudioFile(forWriting: url, settings: outFormat.settings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)
            segments.append(url)
            segFrames = 0
        }
        try openSegment()

        var reachedEnd = false
        while true {
            let outCap = AVAudioFrameCount(Double(readChunk) * targetRate / inFormat.sampleRate) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { throw TranscodeError.formatFailed }
            var convErr: NSError?
            let status = converter.convert(to: outBuffer, error: &convErr) { _, outStatus in
                if reachedEnd { outStatus.pointee = .endOfStream; return nil }
                do { inBuffer.frameLength = 0; try inFile.read(into: inBuffer, frameCount: readChunk) }
                catch { reachedEnd = true; outStatus.pointee = .endOfStream; return nil }
                if inBuffer.frameLength == 0 { reachedEnd = true; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData; return inBuffer
            }
            if let convErr { throw convErr }
            if outBuffer.frameLength > 0 {
                try outFile?.write(from: outBuffer)
                segFrames += AVAudioFramePosition(outBuffer.frameLength)
                if segFrames >= maxFrames && !reachedEnd { try openSegment() }   // 满一段 → 开下一段
            }
            if status == .endOfStream || status == .error { break }
            if reachedEnd && outBuffer.frameLength == 0 { break }
        }
        // 删掉可能的空尾段(刚好切完即结束 → 末段只有 WAV 头)。
        if segments.count > 1, segFrames == 0 {
            try? FileManager.default.removeItem(at: segments.removeLast())
        }
        return segments
    }
}
