package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** [PcmChunker] 分块边界纯逻辑测试。 */
class PcmChunkerTest {

    private fun collect(size: Int, body: (PcmChunker) -> Unit): List<ByteArray> {
        val out = mutableListOf<ByteArray>()
        val c = PcmChunker(size) { out.add(it) }
        body(c)
        return out
    }

    @Test fun `exact single chunk`() {
        val chunks = collect(4) { it.add(byteArrayOf(1, 2, 3, 4), 4) }
        assertEquals(1, chunks.size)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), chunks[0])
    }

    @Test fun `accumulate small reads into one chunk`() {
        val out = mutableListOf<ByteArray>()
        val c = PcmChunker(4) { out.add(it) }
        c.add(byteArrayOf(1, 2), 2)        // 不足一块
        assertTrue("攒够前不应回吐", out.isEmpty())
        c.add(byteArrayOf(3, 4, 5), 3)     // 累计 5 ≥ 4 → 一块,余 [5]
        assertEquals(1, out.size)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), out[0])
        c.flush()
        assertArrayEquals(byteArrayOf(5), out[1])
    }

    @Test fun `single big read splits into multiple chunks plus remainder`() {
        // 10 字节,size=4 → 两块 [0..3][4..7],余 [8,9]
        val data = ByteArray(10) { it.toByte() }
        val chunks = collect(4) { it.add(data, 10) }
        assertEquals(2, chunks.size)
        assertArrayEquals(byteArrayOf(0, 1, 2, 3), chunks[0])
        assertArrayEquals(byteArrayOf(4, 5, 6, 7), chunks[1])
    }

    @Test fun `flush emits remainder`() {
        val out = mutableListOf<ByteArray>()
        val c = PcmChunker(4) { out.add(it) }
        c.add(byteArrayOf(1, 2, 3, 4, 5, 6), 6)   // 一块 [1,2,3,4],余 [5,6]
        assertEquals(1, out.size)
        c.flush()
        assertEquals(2, out.size)
        assertArrayEquals(byteArrayOf(5, 6), out[1])
    }

    @Test fun `flush with no remainder emits nothing`() {
        val out = mutableListOf<ByteArray>()
        val c = PcmChunker(4) { out.add(it) }
        c.add(byteArrayOf(1, 2, 3, 4), 4)
        assertEquals(1, out.size)
        c.flush()
        assertEquals(1, out.size)   // 整除,无残留
    }

    @Test fun `add honors len shorter than array`() {
        // buf 复用场景:数组 8 长但只 read 到 5
        val buf = ByteArray(8) { (it + 1).toByte() }
        val chunks = collect(4) { it.add(buf, 5) }   // 只用前 5:[1,2,3,4,5]
        assertEquals(1, chunks.size)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), chunks[0])
    }

    @Test fun `realistic 6400 byte chunking`() {
        val out = mutableListOf<ByteArray>()
        val c = PcmChunker(6400) { out.add(it) }
        // 模拟 7 次 2048 读 = 14336 字节 → 2 块 6400,余 1536
        val read = ByteArray(2048)
        repeat(7) { c.add(read, 2048) }
        assertEquals(2, out.size)
        out.forEach { assertEquals(6400, it.size) }
        c.flush()
        assertEquals(3, out.size)
        assertEquals(14336 - 12800, out[2].size)   // 1536
    }
}
