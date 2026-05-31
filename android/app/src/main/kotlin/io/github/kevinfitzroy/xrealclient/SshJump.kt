package io.github.kevinfitzroy.xrealclient

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Parameters
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.transport.verification.PromiscuousVerifier
import java.io.Closeable
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

/** 跳板机连接参数(= 另一台 host 的 SSH 接入信息)。由调用方按 [HostConfig.via] 解析得到。 */
data class JumpSpec(
    val host: String,
    val port: Int,
    val user: String,
    val privateKeyPath: String,
    val knownHostsFile: File?,
    /** 非空 → 连跳板这条外层拨号经该 proxy 的本地 SOCKS 隧道(SSH-over-443,SPEC §5.1;归属跳板)。 */
    val proxy: ProxyConfig? = null,
)

/**
 * 多跳 SSH(ProxyJump):先连 [spec] 跳板机(如 TK),经它把本地 `127.0.0.1:`[localPort] 转发到
 * `target:port`(如 OPS:22)。调用方把真正要用的 SSHClient 连到 `127.0.0.1:`[localPort] 即可 ——
 * **SSH 认证是端到端打到 target 的**,跳板机只转发 TCP,不持有 target 凭证(用 `ssh -o ProxyCommand`
 * 实测验证过这条链路:Mac→TK→OPS,OPS key 端到端认证)。
 *
 * 实现用 sshj 的 [LocalPortForwarder](标准跳板做法)。host key 校验:
 * - 跳板连接 → TOFU(真实主机名,正常 pin);
 * - 终点连的是 `127.0.0.1` → TOFU 无意义,故终点连接由调用方用 Promiscuous(传输已被跳板加密、跳板可信)。
 *
 * [close]:关 ServerSocket(转发循环的 accept 抛 SocketException → 后台线程静默退出)+ 断跳板连接。
 */
class SshJump private constructor(
    private val jumpClient: SSHClient,
    private val serverSocket: ServerSocket,
    val localPort: Int,
) : Closeable {

    override fun close() {
        runCatching { serverSocket.close() }
        runCatching { jumpClient.disconnect() }
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 12_000

        /** 阻塞:连跳板 + 建本地转发。失败(连不上跳板/认证失败)直接抛,由调用方按普通 SSH 失败处理。 */
        fun open(spec: JumpSpec, targetHost: String, targetPort: Int): SshJump {
            Crypto.ensureFullBouncyCastle()
            val verifier: HostKeyVerifier = spec.knownHostsFile?.let { TofuKnownHosts(it) } ?: PromiscuousVerifier()
            val jc = SSHClient().apply {
                connectTimeout = CONNECT_TIMEOUT_MS
                // SSH-over-443:跳板带 proxy → 连跳板这条外层拨号经本地 SOCKS 隧道(内层转发已在隧道内)。
                spec.proxy?.let { socketFactory = XrayProxy.socketFactory(it) }
                addHostKeyVerifier(verifier)
                connect(spec.host, spec.port)
                authPublickey(spec.user, spec.privateKeyPath)
            }
            val ss = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress("127.0.0.1", 0))   // 0 = 系统分配临时端口
            }
            val localPort = ss.localPort
            thread(isDaemon = true, name = "ssh-jump-fwd-$localPort") {
                // listen() 阻塞 accept 并逐连接转发;serverSocket.close() 时 accept 抛错 → 退出。
                runCatching {
                    jc.newLocalPortForwarder(
                        Parameters("127.0.0.1", localPort, targetHost, targetPort), ss,
                    ).listen()
                }
            }
            return SshJump(jc, ss, localPort)
        }
    }
}
