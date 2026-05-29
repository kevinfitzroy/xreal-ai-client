package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/**
 * 豆包流式 ASR 二进制协议编解码 ([VolcFrame]) 的 JVM 单测。
 * 纯字节运算 + gzip,无 Android / 网络依赖。
 */
class VolcFrameTest {

    private fun gzip(b: ByteArray): ByteArray =
        ByteArrayOutputStream().also { o -> GZIPOutputStream(o).use { it.write(b) } }.toByteArray()

    private fun gunzip(b: ByteArray): ByteArray =
        GZIPInputStream(b.inputStream()).use { it.readBytes() }

    private fun u32be(v: Int) = byteArrayOf(
        (v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte(),
    )

    // ---- 拼装 ----

    @Test fun `full client request header bytes and gzip roundtrip`() {
        val json = """{"request":{"model_name":"bigmodel"}}""".toByteArray()
        val frame = VolcFrame.buildFullClientRequest(json)

        assertEquals(0x11, frame[0].toInt() and 0xff)   // version1 + headerSize1
        assertEquals(0x10, frame[1].toInt() and 0xff)   // type=full client(0001), flags=0000
        assertEquals(0x11, frame[2].toInt() and 0xff)   // serialization=JSON, compression=Gzip
        assertEquals(0x00, frame[3].toInt() and 0xff)

        val size = ((frame[4].toInt() and 0xff) shl 24) or ((frame[5].toInt() and 0xff) shl 16) or
            ((frame[6].toInt() and 0xff) shl 8) or (frame[7].toInt() and 0xff)
        val payload = frame.copyOfRange(8, frame.size)
        assertEquals(payload.size, size)
        assertArrayEquals(json, gunzip(payload))
    }

    @Test fun `audio intermediate vs last flags`() {
        val pcm = ByteArray(6400) { (it % 256).toByte() }
        val mid = VolcFrame.buildAudio(pcm, last = false)
        val last = VolcFrame.buildAudio(pcm, last = true)

        assertEquals(0x20, mid[1].toInt() and 0xff)    // type=audio(0010), flags=0000
        assertEquals(0x22, last[1].toInt() and 0xff)   // type=audio(0010), flags=0010(最后一包)
        assertEquals(0x01, mid[2].toInt() and 0xff)    // serialization=none, compression=Gzip
        assertArrayEquals(pcm, gunzip(mid.copyOfRange(8, mid.size)))
    }

    // ---- 解析 ----

    /** 按响应格式拼一个 full server response 帧:header(4) + [seq 4] + size(4) + gzip(json)。 */
    private fun serverFrame(json: String, seq: Int?, last: Boolean): ByteArray {
        val out = ByteArrayOutputStream()
        var flags = 0
        if (seq != null) flags = flags or 0b0001
        if (last) flags = flags or 0b0010
        out.write(0x11)                                 // version1 + headerSize1
        out.write((0b1001 shl 4) or flags)              // full server response
        out.write((0b0001 shl 4) or 0b0001)             // JSON + Gzip
        out.write(0x00)
        if (seq != null) out.write(u32be(seq))
        val payload = gzip(json.toByteArray())
        out.write(u32be(payload.size))
        out.write(payload)
        return out.toByteArray()
    }

    @Test fun `parse full server response with sequence`() {
        val json = """{"result":{"text":"ls -la"}}"""
        val parsed = VolcFrame.parse(serverFrame(json, seq = 2, last = false))
        assertTrue(parsed is VolcFrame.Parsed.Server)
        parsed as VolcFrame.Parsed.Server
        assertEquals(2, parsed.sequence)
        assertFalse(parsed.isLast)
        assertEquals(json, parsed.payloadJson)
    }

    @Test fun `parse last packet sets isLast`() {
        val parsed = VolcFrame.parse(serverFrame("""{"result":{"text":"pwd"}}""", seq = 5, last = true))
        parsed as VolcFrame.Parsed.Server
        assertTrue(parsed.isLast)
    }

    @Test fun `parse server response without sequence`() {
        val parsed = VolcFrame.parse(serverFrame("""{"result":{"text":"x"}}""", seq = null, last = false))
        parsed as VolcFrame.Parsed.Server
        assertEquals(null, parsed.sequence)
    }

    @Test fun `parse error frame`() {
        // error 帧:header + code(4) + msgSize(4) + msg,无 seq,无压缩
        val msg = "bad request".toByteArray()
        val out = ByteArrayOutputStream()
        out.write(0x11)
        out.write((0b1111 shl 4) or 0b0000)             // error, flags=0000
        out.write((0b0001 shl 4) or 0b0000)             // JSON, no compression
        out.write(0x00)
        out.write(u32be(45000001))
        out.write(u32be(msg.size))
        out.write(msg)

        val parsed = VolcFrame.parse(out.toByteArray())
        assertTrue(parsed is VolcFrame.Parsed.Err)
        parsed as VolcFrame.Parsed.Err
        assertEquals(45000001, parsed.code)
        assertEquals("bad request", parsed.message)
    }

    @Test fun `build then parse roundtrip via fake server echo`() {
        // 模拟服务端把我们发的 JSON 原样塞回 result.text(只验链路,不验语义)
        val text = "echo hello world"
        val parsed = VolcFrame.parse(serverFrame("""{"result":{"text":"$text"}}""", seq = 1, last = true))
        parsed as VolcFrame.Parsed.Server
        val extracted = org.json.JSONObject(parsed.payloadJson).getJSONObject("result").getString("text")
        assertEquals(text, extracted)
    }
}
