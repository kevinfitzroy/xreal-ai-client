package io.github.kevinfitzroy.xrealclient

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.connection.channel.direct.SessionChannel
import android.util.Log
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import java.io.File
import java.io.InputStream
import java.util.concurrent.Executors

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

    // 所有网络 I/O(write/resize)都丢到这个单线程上跑。两个原因:
    //   1) **绝不能在主线程写 socket** —— dispatchKeyEvent(硬件 Enter/方向键、语音注入)在主线程,
    //      直接 flush 会抛 NetworkOnMainThreadException;sshj 的 ChannelOutputStream.flush 不是异常安全的
    //      (异常跳过内部 wpos 复位),一次就把 channel 缓冲永久写坏 → 之后所有输入恒 ArrayIndexOOB。
    //   2) 单线程天然串行化所有写入(顺序 = 入队顺序),并把 awaitExpansion 阻塞挪出主线程(防 ANR)。
    private val ioExec = Executors.newSingleThreadExecutor { r -> Thread(r, "ssh-io").apply { isDaemon = true } }

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

    /** 异步写:入队到 ssh-io 线程(绝不在调用线程/主线程做 socket I/O)。fire-and-forget,顺序由单线程保证。 */
    override fun write(data: ByteArray) {
        val ch = channel ?: return   // 未连接/已关:静默丢弃(切 project 在途的残留写入)
        ioExec.execute {
            runCatching { ch.outputStream.write(data); ch.outputStream.flush() }
                .onFailure { Log.w(TAG, "channel write failed: ${it.javaClass.simpleName} ${it.message}") }
        }
    }

    override fun resize(cols: Int, rows: Int) {
        // changeWindowDimensions 也是网络 I/O:同样丢到 ssh-io 线程,顺便与数据写入保序。
        // cast 安全:startSession() 实际返回 SessionChannel(实现类,Session 接口未暴露该方法)。
        val s = session as? SessionChannel ?: return
        ioExec.execute { runCatching { s.changeWindowDimensions(cols, rows, 0, 0) } }
    }

    override fun isConnected(): Boolean = client?.isConnected == true

    override fun close() {
        ioExec.shutdownNow()
        runCatching { channel?.close() }
        runCatching { session?.close() }
        runCatching { client?.disconnect() }
        channel = null
        session = null
        client = null
    }

    private companion object { const val TAG = "SshConnection" }
}
