import Foundation
import AVFoundation

/// 16kHz mono PCM_16BIT 录音,**流式**输出 —— Android `AudioRecorder.kt` 的 port(iOS = AVAudioEngine)。
///
/// inputNode tap(设备原生采样率/声道,通常 48k float)→ `AVAudioConverter` 转 16k/mono/Int16
/// → `PcmChunker` 攒成 ~200ms 定长块(裸 PCM16LE,无 WAV 头)实时回吐。
///
/// 需要麦克风权限 —— 调用方先确认。
final class AudioCapture {

    /// 200ms @ 16kHz·16bit·mono = 6400 bytes(豆包推荐单包 200ms)。
    private static let chunkBytes = 6400
    private static let targetRate: Double = 16000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat!
    private var chunker: PcmChunker?
    private var running = false
    private var tapBlocks = 0

    /// 开始采集。`onChunk` 在录音线程(tap 回调线程)调用,携带裸 PCM16LE 16k mono。
    /// 返回 false = 启动失败(AudioSession / engine 起不来)。
    @discardableResult
    func start(onChunk: @escaping (Data) -> Void) -> Bool {
        guard !running else { return true }

        let session = AVAudioSession.sharedInstance()
        do {
            // .record 即可(本期只录不放);.playAndRecord 留给以后 TTS。defaultToSpeaker 不需要。
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            NSLog("[AudioCapture] AVAudioSession setup failed: \(error.localizedDescription)")
            return false
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            NSLog("[AudioCapture] invalid input format \(inputFormat)")
            return false
        }
        // 目标:16k mono Int16 interleaved(= 裸 PCM16LE)。
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.targetRate,
                                         channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: outFmt) else {
            NSLog("[AudioCapture] cannot build converter from \(inputFormat)")
            return false
        }
        outputFormat = outFmt
        converter = conv
        let ch = PcmChunker(size: Self.chunkBytes, sink: onChunk)
        chunker = ch

        // tap buffer ~ 100ms;转换后按比例缩到 16k。
        let tapFrames = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer, into: ch)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("[AudioCapture] engine start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }
        running = true
        NSLog("[AudioCapture] started: in=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch → 16k/mono/Int16")
        return true
    }

    /// 停止采集:冲出尾块、移 tap、停 engine、释放 AudioSession。
    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunker?.flush()
        chunker = nil
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 取消:丢弃尾块,不回吐(用于 ESC / 重按)。
    func cancel() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunker = nil
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 把一块 tap buffer 转成 16k/mono/Int16 并喂 chunker。采样率非 1:1,用 inputBlock 模式转换。
    private func convertAndEmit(_ input: AVAudioPCMBuffer, into ch: PcmChunker) {
        guard let converter, let outputFormat else { return }
        // 输出帧数按采样率比例估算 + 余量。
        let ratio = Self.targetRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

        var fed = false
        var convErr: NSError?
        let status = converter.convert(to: outBuffer, error: &convErr) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if let convErr {
            NSLog("[AudioCapture] convert error: \(convErr.localizedDescription)")
            return
        }
        guard status != .error, outBuffer.frameLength > 0,
              let int16 = outBuffer.int16ChannelData else { return }
        let byteCount = Int(outBuffer.frameLength) * 2   // mono Int16
        let data = Data(bytes: int16[0], count: byteCount)
        #if DEBUG
        // 每 ~20 块打一次(只打帧数,不打音频内容)—— 验证 tap 在转、转换出非零 16k buffer。
        tapBlocks += 1
        if tapBlocks % 20 == 1 {
            NSLog("[AudioCapture] tap#\(tapBlocks) in=\(input.frameLength)f@\(Int(input.format.sampleRate)) → out=\(outBuffer.frameLength)f@16k (\(byteCount)B)")
        }
        #endif
        ch.add(data)
    }
}

/// 把任意大小的 PCM 攒成固定 `size` 的块回吐给 `sink`;尾部不足一块的留到 `flush`。
/// Android `PcmChunker` 的 port —— 纯逻辑,无 AV 依赖。
final class PcmChunker {
    private let size: Int
    private let sink: (Data) -> Void
    private var buf = Data()

    init(size: Int, sink: @escaping (Data) -> Void) {
        self.size = size
        self.sink = sink
    }

    func add(_ data: Data) {
        buf.append(data)
        guard buf.count >= size else { return }
        var off = 0
        while buf.count - off >= size {
            sink(buf.subdata(in: off ..< off + size))
            off += size
        }
        buf = off < buf.count ? buf.subdata(in: off ..< buf.count) : Data()
    }

    /// 冲出尾部不足一块的残留(录音正常结束时调一次)。
    func flush() {
        if !buf.isEmpty {
            sink(buf)
            buf = Data()
        }
    }
}
