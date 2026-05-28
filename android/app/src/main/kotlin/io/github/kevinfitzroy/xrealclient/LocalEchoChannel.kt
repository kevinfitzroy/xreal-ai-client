package io.github.kevinfitzroy.xrealclient

import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream

/**
 * Phase 0.5 验证用:内存 echo PTY。
 *
 * 行为:写入 outputStream() 的每个字节,立刻可以从 inputStream() 读出。
 * 等价于 server 端跑 `cat` 但没有 \r→\r\n 转换 —— 已经在写之前做了。
 *
 * 用途:0.5 写完 TerminalBridge 后,在 Activity 里用 LocalEchoChannel
 * 作为 PtyChannel 实现,验证 keystroke → bridge → channel → bridge → webview
 * 的双向通路。0.3 SSH 就绪后,换成 SshConnection 即可。
 */
class LocalEchoChannel : PtyChannel {

    private val pipeOut = PipedOutputStream()
    private val pipeIn = PipedInputStream(pipeOut, 8192)

    private val writeStream = object : OutputStream() {
        override fun write(b: Int) {
            // \r 转 \r\n,模拟 shell 行模式
            if (b == '\r'.code) pipeOut.write('\r'.code).also { pipeOut.write('\n'.code) }
            else pipeOut.write(b)
        }
        override fun write(b: ByteArray, off: Int, len: Int) {
            for (i in off until off + len) write(b[i].toInt() and 0xff)
        }
        override fun flush() { pipeOut.flush() }
        override fun close() { pipeOut.close() }
    }

    override fun inputStream(): InputStream = pipeIn
    override fun outputStream(): OutputStream = writeStream
    override fun resize(cols: Int, rows: Int) { /* echo mode 不关心 */ }
    override fun isConnected(): Boolean = true
    override fun close() {
        runCatching { writeStream.close() }
        runCatching { pipeIn.close() }
    }
}
