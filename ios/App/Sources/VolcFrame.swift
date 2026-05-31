import Foundation
import zlib

/// 火山引擎(豆包)大模型流式 ASR 的 WebSocket 二进制协议编解码 —— Android `VolcFrame.kt` 的逐字节 port。
///
/// 纯函数,不碰网络(便于自检,见 VolcFrameSelfCheck)。WS 收发由 `VolcAsr` 负责。
///
/// 帧结构(整数均**大端**):
///   byte0  = (version<<4)|headerSize    固定 0x11(version 1,header 4 字节)
///   byte1  = (messageType<<4)|flags
///   byte2  = (serialization<<4)|compression
///   byte3  = reserved(0)
///   [sequence 4B] —— 仅当 flags 含 seq bit(响应才有;本 client 发包不带)
///   payloadSize 4B
///   payload(gzip 压缩;JSON 时按 serialization)
///
/// ⚠️ 压缩**必须是真 gzip**(`1f 8b` magic):帧头声明 compression=GZIP,服务端会 gunzip。
/// Apple `Compression`/`COMPRESSION_ZLIB` 出的是裸 DEFLATE,服务端会拒;这里用 zlib `deflateInit2`
/// windowBits=31 = 真 gzip。
enum VolcFrame {

    private static let B0: UInt8 = 0x11  // version=1, header size=1 (×4 = 4 bytes)

    // message type(byte1 高 4 位)
    private static let T_FULL_CLIENT = 0b0001
    private static let T_AUDIO       = 0b0010
    private static let T_FULL_SERVER = 0b1001
    private static let T_ERROR       = 0b1111

    // flags(byte1 低 4 位):bit0 = 带 sequence,bit1 = 最后一包(负包)
    private static let F_NONE = 0b0000
    private static let F_LAST = 0b0010

    // serialization(byte2 高 4 位) / compression(byte2 低 4 位)
    private static let S_NONE = 0b0000
    private static let S_JSON = 0b0001
    private static let C_GZIP = 0b0001

    /// full client request:JSON(gzip)。WS 建连后第一个包。
    static func buildFullClientRequest(_ jsonUtf8: Data) -> Data {
        frame(b1(T_FULL_CLIENT, F_NONE), b2(S_JSON, C_GZIP), gzip(jsonUtf8))
    }

    /// audio only request:裸 PCM(gzip)。`last` 标记最后一包(负包)。
    static func buildAudio(_ pcmChunk: Data, last: Bool) -> Data {
        frame(b1(T_AUDIO, last ? F_LAST : F_NONE), b2(S_NONE, C_GZIP), gzip(pcmChunk))
    }

    enum Parsed {
        /// 服务端识别结果。`payloadJson` 形如 `{"result":{"text":"…"}}`。`isLast`=最后一包结果。
        case server(sequence: Int?, isLast: Bool, payloadJson: String)
        /// 服务端错误帧(messageType 0b1111)。
        case error(code: Int, message: String)
        /// 未知/不关心的消息类型。
        case unknown(type: Int)
    }

    /// 收 16 字节头部 hex,定位豆包实际帧格式(防越界 + 排查用)。
    private static func hex(_ b: [UInt8]) -> String {
        b.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func parse(_ bytes: Data) -> Parsed {
        let b = [UInt8](bytes)
        guard b.count >= 4 else { NSLog("[VolcFrame] 帧太短 \(b.count)B"); return .unknown(type: -1) }
        let headerLen = (Int(b[0]) & 0x0f) * 4
        let type  = (Int(b[1]) >> 4) & 0x0f
        let flags = Int(b[1]) & 0x0f
        let comp  = Int(b[2]) & 0x0f
        // 每帧打头部,看豆包实际发什么(type/flags/headerLen + hex)
        NSLog("[VolcFrame] in \(b.count)B type=\(type) flags=\(flags) hdr=\(headerLen) comp=\(comp) hex=\(hex(b))")
        var pos = headerLen
        var seq: Int? = nil
        if flags & 0b0001 != 0 {
            guard pos + 4 <= b.count else { NSLog("[VolcFrame] seq 越界,\(b.count)B left=\(b.count-pos)"); return .unknown(type: type) }
            seq = readI32BE(b, pos); pos += 4
        }
        let isLast = (flags & F_LAST) != 0
        switch type {
        case T_FULL_SERVER:
            guard pos + 4 <= b.count else { NSLog("[VolcFrame] size 字段越界 pos=\(pos) count=\(b.count)"); return .unknown(type: type) }
            let size = readU32BE(b, pos); pos += 4
            guard size >= 0, pos + size <= b.count else {
                NSLog("[VolcFrame] payload 越界 size=\(size) left=\(b.count-pos) hex=\(hex(b))")
                return .unknown(type: type)
            }
            let raw = Data(b[pos ..< pos + size])
            let json = String(decoding: maybeGunzip(raw, comp), as: UTF8.self)
            return .server(sequence: seq, isLast: isLast, payloadJson: json)
        case T_ERROR:
            guard pos + 8 <= b.count else { return .error(code: -1, message: "短错误帧") }
            let code = readI32BE(b, pos); pos += 4
            let msz = readU32BE(b, pos); pos += 4
            guard msz >= 0, pos + msz <= b.count else { return .error(code: code, message: "") }
            let raw = Data(b[pos ..< pos + msz])
            let msg = String(decoding: maybeGunzip(raw, comp), as: UTF8.self)
            return .error(code: code, message: msg)
        default:
            return .unknown(type: type)
        }
    }

    // ---- 帧拼装 / 字节序 / 压缩 ----

    private static func b1(_ type: Int, _ flags: Int) -> UInt8 { UInt8(((type << 4) | flags) & 0xff) }
    private static func b2(_ ser: Int, _ comp: Int) -> UInt8 { UInt8(((ser << 4) | comp) & 0xff) }

    private static func frame(_ byte1: UInt8, _ byte2: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: 8 + payload.count)
        out.append(B0); out.append(byte1); out.append(byte2); out.append(0)
        appendU32BE(&out, payload.count)
        out.append(payload)
        return out
    }

    private static func maybeGunzip(_ raw: Data, _ comp: Int) -> Data {
        comp == C_GZIP ? gunzip(raw) : raw
    }

    // MARK: - 真 gzip(zlib windowBits=31)

    /// zlib `deflateInit2` windowBits=31 → gzip 流(`1f 8b` magic + CRC32),与 Java GZIPOutputStream
    /// 产物**结构**一致(mtime/OS 字节可能不同,但 gunzip 后内容一致,服务端按内容解)。
    static func gzip(_ data: Data) -> Data {
        if data.isEmpty {
            // 空负包:仍需合法 gzip(空内容)。走同一路径即可(zlib 能编空流)。
        }
        var stream = z_stream()
        // windowBits 15 | 16 = 31 → gzip wrapper;memLevel 8,默认压缩级。
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8,
                                   Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return data }   // 不应发生;降级返回原文(自检会抓到)
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16384
        var outBuf = [UInt8](repeating: 0, count: chunkSize)
        var input = [UInt8](data)
        let inputCount = input.count

        input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inputCount)
            repeat {
                outBuf.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    let produced = chunkSize - Int(stream.avail_out)
                    output.append(outPtr.baseAddress!, count: produced)
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    /// zlib inflate,windowBits=47 = 自动识别 gzip / zlib。
    static func gunzip(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        var status = inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return data }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16384
        var outBuf = [UInt8](repeating: 0, count: chunkSize)
        var input = [UInt8](data)
        let inputCount = input.count

        input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inputCount)
            repeat {
                outBuf.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkSize - Int(stream.avail_out)
                    output.append(outPtr.baseAddress!, count: produced)
                }
            } while status == Z_OK
        }
        return output
    }

    // MARK: - 大端字节序

    private static func appendU32BE(_ buf: inout Data, _ v: Int) {
        buf.append(UInt8((v >> 24) & 0xff)); buf.append(UInt8((v >> 16) & 0xff))
        buf.append(UInt8((v >> 8) & 0xff));  buf.append(UInt8(v & 0xff))
    }

    private static func readU32BE(_ buf: [UInt8], _ off: Int) -> Int {
        (Int(buf[off]) << 24) | (Int(buf[off + 1]) << 16) | (Int(buf[off + 2]) << 8) | Int(buf[off + 3])
    }

    /// 与 readU32BE 同实现(语义上允许负数:error code)。
    private static func readI32BE(_ buf: [UInt8], _ off: Int) -> Int { readU32BE(buf, off) }
}
