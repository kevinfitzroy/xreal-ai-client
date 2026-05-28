package io.github.kevinfitzroy.xrealclient

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.IOUtils
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import java.io.Closeable
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 状态探测用的 per-host SSH 连接 —— 与终端的交互式 [SshConnection] 分开,只做一次性 exec。
 *
 * 关键设计([StatusPoller] 的 O(hosts) 而非 O(projects)):一台 host 上的所有 session
 * **一条 exec** 批量抓,不是每个 project 各开一个 channel。脚本用 `===session===` 分隔,
 * tmux 失败(无 server / 无 session)兜底 `__NOSESSION__`,由 [AgentStatusDetector] 判 DISCONNECTED。
 *
 * 连接惰性建立,异常即关闭 → 下次 poll 自动重连。
 */
class HostClient(
    private val host: String,
    private val port: Int = 22,
    private val user: String,
    private val privateKeyPath: String,
    private val knownHostsFile: File? = null,
) : Closeable {

    private var client: SSHClient? = null

    private fun ensure(): SSHClient {
        client?.let { if (it.isConnected) return it }
        runCatching { client?.disconnect() }
        val verifier: HostKeyVerifier = knownHostsFile?.let { TofuKnownHosts(it) } ?: PromiscuousVerifier()
        val c = SSHClient().apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            timeout = READ_TIMEOUT_MS
            addHostKeyVerifier(verifier)
            connect(host, port)
            authPublickey(user, privateKeyPath)
        }
        client = c
        return c
    }

    /**
     * 一次 exec 抓所有 session 的可见屏。返回 sessionName → paneText。
     * 任何 SSH 层失败 → 关连接 + 所有 session 返回 [NO_SESSION_SENTINEL](让上层判 DISCONNECTED)。
     */
    fun captureAll(sessions: List<String>): Map<String, String> {
        val safe = sessions.filter { SAFE.matches(it) }
        if (safe.isEmpty()) return emptyMap()
        return try {
            // LANG/LC_ALL=UTF-8 + `tmux -u`:capture-pane 输出 UTF-8(否则多字节降级成 `_`)。
            // PATH 前缀:非交互 SSH exec 的 PATH 很窄,常缺 tmux 所在目录。
            val envPrefix = "export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; export PATH=\"\$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin\"\n"
            val script = envPrefix + safe.joinToString("\n") { s ->
                "echo '$DELIM_OPEN$s$DELIM_CLOSE'; tmux -u capture-pane -p -t '$s' 2>&1 || echo '$NO_SESSION_SENTINEL'"
            }
            val out = runExec(script)
            parse(out, safe)
        } catch (e: Exception) {
            android.util.Log.w("HostClient", "captureAll($host:$port) 失败: ${e.javaClass.simpleName}: ${e.message}")
            runCatching { close() }
            safe.associateWith { NO_SESSION_SENTINEL }
        }
    }

    /** cat 一个文件(给 ManifestFetcher 读 manifest)。SSH 层失败 → null(关连接,下次重连)。 */
    fun catFile(path: String): String? = try {
        runExec("cat '$path' 2>/dev/null")
    } catch (e: Exception) {
        android.util.Log.w("HostClient", "catFile($host:$port) 失败: ${e.javaClass.simpleName}: ${e.message}")
        runCatching { close() }
        null
    }

    private fun runExec(script: String): String {
        val session = ensure().startSession()
        try {
            val cmd = session.exec(script)
            val out = IOUtils.readFully(cmd.inputStream).toString()
            cmd.join(EXEC_TIMEOUT_SEC, TimeUnit.SECONDS)
            return out
        } finally {
            runCatching { session.close() }
        }
    }

    /** 按 `===session===` header 切段;未出现的 session 兜底 sentinel。 */
    private fun parse(out: String, sessions: List<String>): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        var current: String? = null
        val buf = StringBuilder()
        fun flush() { current?.let { result[it] = buf.toString().trim('\n') }; buf.clear() }
        for (line in out.lineSequence()) {
            val m = HEADER.matchEntire(line.trim())
            if (m != null) { flush(); current = m.groupValues[1] } else if (current != null) { buf.append(line).append('\n') }
        }
        flush()
        return sessions.associateWith { result[it] ?: NO_SESSION_SENTINEL }
    }

    override fun close() {
        runCatching { client?.disconnect() }
        client = null
    }

    companion object {
        const val NO_SESSION_SENTINEL = "__NOSESSION__"
        private const val DELIM_OPEN = "==="
        private const val DELIM_CLOSE = "==="
        private const val EXEC_TIMEOUT_SEC = 8L
        private const val CONNECT_TIMEOUT_MS = 8000
        private const val READ_TIMEOUT_MS = 8000
        private val SAFE = Regex("[A-Za-z0-9_.-]+")
        private val HEADER = Regex("^===(.+)===$")
    }
}
