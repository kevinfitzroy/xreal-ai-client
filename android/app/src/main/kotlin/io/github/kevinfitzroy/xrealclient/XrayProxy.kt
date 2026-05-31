package io.github.kevinfitzroy.xrealclient

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import javax.net.SocketFactory

/**
 * SSH-over-443 隧道运行时(SPEC.md §5.1):内嵌 xray-core 起一个**仅本地** SOCKS5,
 * 把 app 的 SSH socket 经它转发到 host:443 的 vmess 服务 → 绕过 GFW 对 :22 的限速。
 *
 * **xray-core 经 gomobile 产物 `xraybridge.aar` 反射调用**(见 `xray-bridge/`)。aar 不存在时
 * [available] 返回 false,[socketFactory] 抛异常 → 调用方按"代理不可用 → 该 host 连接失败"处理,
 * **不影响直连 host**(SPEC §9 优雅降级)。这样未 build wrapper 也能正常编译运行(只是隧道功能不可用)。
 *
 * 一个 proxy(按 [ProxyConfig.name])= 一个 xray 实例 + 一个本地 SOCKS 端口,进程级常驻、按需惰性启动。
 */
object XrayProxy {

    private const val TAG = "XrayProxy"
    private const val BRIDGE_CLASS = "xraybridge.Xraybridge"

    private val lock = Any()
    /** proxy 名 → 已分配的本地 SOCKS 端口(已启动)。 */
    private val ports = HashMap<String, Int>()

    /** gomobile 产物在不在(决定隧道功能是否可用)。 */
    fun available(): Boolean = bridgeClass != null

    private val bridgeClass: Class<*>? by lazy {
        runCatching { Class.forName(BRIDGE_CLASS) }
            .onFailure { AppLog.i(TAG, "xraybridge.aar 未集成 → SSH-over-443 隧道不可用(直连 host 不受影响)") }
            .getOrNull()
    }

    /**
     * 确保 [proxy] 的 xray 实例在跑,返回其本地 SOCKS 端口。幂等(同 proxy 复用)。
     * aar 缺失 / vmess 解析失败 / xray 启动失败 → 抛异常。
     */
    private fun ensureStarted(proxy: ProxyConfig): Int = synchronized(lock) {
        ports[proxy.name]?.let { return it }
        val cls = bridgeClass ?: throw IllegalStateException("xraybridge.aar 未集成,SSH-over-443 不可用")

        val link = XrayConfig.parseVmess(proxy.url)
        val port = freeLocalPort()
        val config = XrayConfig.buildXrayConfig(link, port)

        // gomobile:Go `func Start(key, cfg)` → Java static `Xraybridge.start(String,String)`(首字母小写)。
        val start = findMethod(cls, "start", String::class.java, String::class.java)
        start.invoke(null, proxy.name, config)   // 抛 InvocationTargetException(裹 Go error)即启动失败
        ports[proxy.name] = port
        AppLog.i(TAG, "xray 起 proxy='${proxy.name}' (${link.address}:${link.port}) → SOCKS 127.0.0.1:$port")
        return port
    }

    /**
     * 取一个经 [proxy] 隧道拨号的 [SocketFactory](注入 sshj 的 `SSHClient.setSocketFactory`)。
     * 返回前确保 xray 已启动。SSH 的 socket 会经 `127.0.0.1:<SOCKS 口>` → vmess/tls:443 出去。
     */
    fun socketFactory(proxy: ProxyConfig): SocketFactory {
        val socksPort = ensureStarted(proxy)
        val socksProxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", socksPort))
        return SocksSocketFactory(socksProxy)
    }

    /** 关掉所有 xray 实例(Activity 销毁时调;幂等)。 */
    fun stopAll() = synchronized(lock) {
        val cls = bridgeClass ?: return
        val stop = runCatching { findMethod(cls, "stop", String::class.java) }.getOrNull()
        ports.keys.toList().forEach { name -> runCatching { stop?.invoke(null, name) } }
        ports.clear()
    }

    /** 系统分配一个空闲本地端口(开了立刻关,xray 随后 bind;窗口极小可接受)。 */
    private fun freeLocalPort(): Int =
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }

    /** gomobile 方法名通常首字母小写;兜底也试原名。 */
    private fun findMethod(cls: Class<*>, name: String, vararg params: Class<*>) =
        runCatching { cls.getMethod(name, *params) }
            .getOrElse { cls.getMethod(name.replaceFirstChar { c -> c.uppercase() }, *params) }

    /** 所有 createSocket 都返回一个绑定到 SOCKS 代理的 Socket;sshj 随后对它 connect(host:port)。 */
    private class SocksSocketFactory(private val proxy: Proxy) : SocketFactory() {
        override fun createSocket(): Socket = Socket(proxy)

        override fun createSocket(host: String, port: Int): Socket =
            Socket(proxy).apply { connect(InetSocketAddress(host, port)) }

        override fun createSocket(host: String, port: Int, localAddr: InetAddress, localPort: Int): Socket =
            Socket(proxy).apply { bind(InetSocketAddress(localAddr, localPort)); connect(InetSocketAddress(host, port)) }

        override fun createSocket(host: InetAddress, port: Int): Socket =
            Socket(proxy).apply { connect(InetSocketAddress(host, port)) }

        override fun createSocket(host: InetAddress, port: Int, localAddr: InetAddress, localPort: Int): Socket =
            Socket(proxy).apply { bind(InetSocketAddress(localAddr, localPort)); connect(InetSocketAddress(host, port)) }
    }
}
