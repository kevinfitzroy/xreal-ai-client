package io.github.kevinfitzroy.xrealclient

import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/**
 * 火山引擎(豆包)大模型流式 ASR 的 WebSocket 二进制协议编解码。
 *
 * 纯函数,不碰网络 —— 便于 JVM 单测(见 VolcFrameTest)。WS 收发由 [VolcEngineAsr] 负责。
 *
 * 帧结构(整数均**大端**):
 *   byte0  = (version<<4)|headerSize    固定 0x11(version 1,header 4 字节)
 *   byte1  = (messageType<<4)|flags
 *   byte2  = (serialization<<4)|compression
 *   byte3  = reserved(0)
 *   [sequence 4B] —— 仅当 flags 含 seq bit(响应才有;本 client 发包不带)
 *   payloadSize 4B(client req / full server response)
 *   payload(按 compression 压缩;JSON 时按 serialization)
 *
 * 协议文档:refs/大模型流式语音识别API.md(双向流式优化版 bigmodel_async)。
 */
internal object VolcFrame {

    private const val B0 = 0x11  // version=1, header size=1 (×4 = 4 bytes)

    // message type(byte1 高 4 位)
    private const val T_FULL_CLIENT = 0b0001
    private const val T_AUDIO = 0b0010
    private const val T_FULL_SERVER = 0b1001
    private const val T_ERROR = 0b1111

    // flags(byte1 低 4 位):bit0 = 带 sequence,bit1 = 最后一包(负包)
    private const val F_NONE = 0b0000
    private const val F_LAST = 0b0010

    // serialization(byte2 高 4 位) / compression(byte2 低 4 位)
    private const val S_NONE = 0b0000
    private const val S_JSON = 0b0001
    private const val C_GZIP = 0b0001

    /** full client request:JSON(gzip)。WS 建连后第一个包。 */
    fun buildFullClientRequest(jsonUtf8: ByteArray): ByteArray =
        frame(b1(T_FULL_CLIENT, F_NONE), b2(S_JSON, C_GZIP), gzip(jsonUtf8))

    /** audio only request:裸 PCM(gzip)。[last] 标记最后一包(负包)。 */
    fun buildAudio(pcmChunk: ByteArray, last: Boolean): ByteArray =
        frame(b1(T_AUDIO, if (last) F_LAST else F_NONE), b2(S_NONE, C_GZIP), gzip(pcmChunk))

    sealed class Parsed {
        /** 服务端识别结果。[payloadJson] 形如 `{"result":{"text":"…"}}`。[isLast]=最后一包结果。 */
        data class Server(val sequence: Int?, val isLast: Boolean, val payloadJson: String) : Parsed()
        /** 服务端错误帧(messageType 0b1111)。 */
        data class Err(val code: Int, val message: String) : Parsed()
        /** 未知/不关心的消息类型。 */
        data class Unknown(val type: Int) : Parsed()
    }

    fun parse(bytes: ByteArray): Parsed {
        require(bytes.size >= 4) { "frame too short: ${bytes.size}" }
        val headerLen = (bytes[0].toInt() and 0x0f) * 4
        val type = (bytes[1].toInt() ushr 4) and 0x0f
        val flags = bytes[1].toInt() and 0x0f
        val comp = bytes[2].toInt() and 0x0f
        var pos = headerLen
        val seq = if (flags and 0b0001 != 0) readI32BE(bytes, pos).also { pos += 4 } else null
        val isLast = flags and F_LAST != 0
        return when (type) {
            T_FULL_SERVER -> {
                val size = readU32BE(bytes, pos); pos += 4
                val raw = bytes.copyOfRange(pos, pos + size)
                Parsed.Server(seq, isLast, String(maybeGunzip(raw, comp), Charsets.UTF_8))
            }
            T_ERROR -> {
                val code = readI32BE(bytes, pos); pos += 4
                val msz = readU32BE(bytes, pos); pos += 4
                val raw = bytes.copyOfRange(pos, pos + msz)
                Parsed.Err(code, String(maybeGunzip(raw, comp), Charsets.UTF_8))
            }
            else -> Parsed.Unknown(type)
        }
    }

    // ---- 帧拼装 / 字节序 / 压缩 ----

    private fun b1(type: Int, flags: Int) = ((type shl 4) or flags) and 0xff
    private fun b2(ser: Int, comp: Int) = ((ser shl 4) or comp) and 0xff

    private fun frame(byte1: Int, byte2: Int, payload: ByteArray): ByteArray {
        val out = ByteArray(8 + payload.size)
        out[0] = B0.toByte(); out[1] = byte1.toByte(); out[2] = byte2.toByte(); out[3] = 0
        writeU32BE(out, 4, payload.size)
        System.arraycopy(payload, 0, out, 8, payload.size)
        return out
    }

    private fun maybeGunzip(raw: ByteArray, comp: Int) = if (comp == C_GZIP) gunzip(raw) else raw

    private fun gzip(data: ByteArray): ByteArray {
        val bos = ByteArrayOutputStream(data.size)
        GZIPOutputStream(bos).use { it.write(data) }
        return bos.toByteArray()
    }

    private fun gunzip(data: ByteArray): ByteArray =
        GZIPInputStream(data.inputStream()).use { it.readBytes() }

    private fun writeU32BE(buf: ByteArray, off: Int, v: Int) {
        buf[off] = (v ushr 24).toByte(); buf[off + 1] = (v ushr 16).toByte()
        buf[off + 2] = (v ushr 8).toByte(); buf[off + 3] = v.toByte()
    }

    private fun readU32BE(buf: ByteArray, off: Int): Int =
        ((buf[off].toInt() and 0xff) shl 24) or ((buf[off + 1].toInt() and 0xff) shl 16) or
            ((buf[off + 2].toInt() and 0xff) shl 8) or (buf[off + 3].toInt() and 0xff)

    /** 与 readU32BE 同实现,但语义上允许负数(error code / 负 sequence)。 */
    private fun readI32BE(buf: ByteArray, off: Int): Int = readU32BE(buf, off)
}
