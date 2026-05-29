package io.github.kevinfitzroy.xrealclient

import java.io.Closeable
import java.io.InputStream

/**
 * 终端字节流双向通道 + 尺寸调整。
 *
 * 三个实现:
 *   [SshConnection]    — 主路径:sshj over SSH/PTY
 *   [LocalEchoChannel] — Phase 0.5 验证用:内存 echo,无需 SSH
 *   (Stage A.2 fallback) sshlib (ConnectBot) wrapper — 如果 sshj BC 在真机挂
 *
 * **写入必须走 [write]**(原子 write+flush,实现内部加锁串行化)。不暴露裸 outputStream:
 * sshj 的 ChannelOutputStream 跨线程并发 write/flush 会把内部缓冲 wpos 写成负数、永久损坏
 * (终端输入在 WebView IO 线程、语音注入在主线程,曾因此一用语音终端输入就全死)。
 */
interface PtyChannel : Closeable {
    fun inputStream(): InputStream
    /** 原子写入(write+flush 在一把锁内完成)。所有写入方(终端/语音/调试直通)都经此串行化。 */
    fun write(data: ByteArray)
    fun resize(cols: Int, rows: Int)
    fun isConnected(): Boolean
}
