package io.github.kevinfitzroy.xrealclient

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.connection.channel.direct.SessionChannel
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * 单 SSH 连接 + PTY + 自定义启动命令(默认 abduco session)。
 *
 * 启动命令通过构造参数注入,见 docs/session-persistence-options.md:
 *   "abduco -A dev bash"      默认
 *   "tmux new -A -s dev"      备选
 *   "screen -DR dev"          备选
 *
 * Host key 验证:
 *   knownHostsFile == null → [PromiscuousVerifier](接受任意 host,**只用于测试**)
 *   knownHostsFile != null → [TofuKnownHosts](TOFU,持久化到该文件)
 */
class SshConnection(
    private val host: String,
    private val port: Int = 22,
    private val user: String,
    private val privateKeyPath: String,
    private val startupCommand: String = "abduco -A dev bash",
    private val knownHostsFile: File? = null,
) : PtyChannel {

    private var client: SSHClient? = null
    private var session: Session? = null
    private var channel: Session.Command? = null

    fun connect(cols: Int, rows: Int) {
        check(client == null) { "SshConnection.connect() 已调用过" }
        Crypto.ensureFullBouncyCastle()   // X25519 KEX 需完整 BC(幂等,见 Crypto)

        val verifier: HostKeyVerifier = knownHostsFile?.let { TofuKnownHosts(it) }
            ?: PromiscuousVerifier()

        val c = SSHClient().apply {
            addHostKeyVerifier(verifier)
            connect(host, port)
            authPublickey(user, privateKeyPath)
        }
        val s = c.startSession().apply {
            allocatePTY("xterm-256color", cols, rows, 0, 0, emptyMap())
        }
        // exec 而非 startShell:把入口直接设成 abduco/tmux,远端 shell 一启就接入 session。
        val cmd = s.exec(startupCommand)
        client = c
        session = s
        channel = cmd
    }

    override fun inputStream(): InputStream =
        checkNotNull(channel) { "未 connect()" }.inputStream

    override fun outputStream(): OutputStream =
        checkNotNull(channel) { "未 connect()" }.outputStream

    override fun resize(cols: Int, rows: Int) {
        // changeWindowDimensions 在 SessionChannel(实现类),不在 Session 接口。
        // startSession() 实际返回的就是 SessionChannel,cast 安全。
        (session as? SessionChannel)?.changeWindowDimensions(cols, rows, 0, 0)
    }

    override fun isConnected(): Boolean = client?.isConnected == true

    override fun close() {
        runCatching { channel?.close() }
        runCatching { session?.close() }
        runCatching { client?.disconnect() }
        channel = null
        session = null
        client = null
    }
}
