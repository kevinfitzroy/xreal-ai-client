package io.github.kevinfitzroy.xrealclient

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream

/**
 * 终端字节流双向通道 + 尺寸调整。
 *
 * 三个实现:
 *   [SshConnection]    — 主路径:sshj over SSH/PTY
 *   [LocalEchoChannel] — Phase 0.5 验证用:内存 echo,无需 SSH
 *   (Stage A.2 fallback) sshlib (ConnectBot) wrapper — 如果 sshj BC 在真机挂
 */
interface PtyChannel : Closeable {
    fun inputStream(): InputStream
    fun outputStream(): OutputStream
    fun resize(cols: Int, rows: Int)
    fun isConnected(): Boolean
}
