import Foundation

/// 流式把 **16k / mono / 16-bit PCM** 写成 WAV 文件:先写占位头,音频边来边 append,`finalize()` 时回填
/// RIFF / data 长度。给「按住说话 → 上滑锁定录音」用 —— 音频本来就在采(喂 ASR),顺手 tee 一份成 WAV,
/// 一旦锁定即得**从按下第一秒起**的完整录音(无缝、且已是 16k WAV,省下游一次转码)。
final class PcmWavWriter {
    private let url: URL
    private var handle: FileHandle?
    private var dataBytes: UInt32 = 0

    private static let sampleRate: UInt32 = 16000
    private static let channels: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16

    init?(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        try? h.write(contentsOf: Self.header(dataBytes: 0))   // 占位头,finalize 回填
    }

    /// 追加一块裸 PCM16LE(录音线程调用)。
    func append(_ pcm: Data) {
        guard let h = handle, !pcm.isEmpty else { return }
        try? h.write(contentsOf: pcm)
        dataBytes &+= UInt32(pcm.count)
    }

    /// 回填长度并关闭,返回文件 URL(nil = 已关/无效)。
    @discardableResult
    func finalize() -> URL? {
        guard let h = handle else { return nil }
        try? h.seek(toOffset: 0)
        try? h.write(contentsOf: Self.header(dataBytes: dataBytes))
        try? h.close()
        handle = nil
        return dataBytes > 0 ? url : nil
    }

    /// 关闭并删文件(取消录音)。
    func discard() {
        try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    private static func header(dataBytes: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(36 &+ dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(dataBytes)
        return d
    }
}
