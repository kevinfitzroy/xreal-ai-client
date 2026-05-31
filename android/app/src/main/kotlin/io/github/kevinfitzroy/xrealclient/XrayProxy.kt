package io.github.kevinfitzroy.xrealclient

import java.net.InetAddress
import java.net.ServerSocket

/**
 * SSH-over-443 隧道运行时(SPEC.md §5.1):内嵌 xray-core 起一个**仅本地** dokodemo-door inbound,
 * 把进来的 SSH 连接 **override 改写成服务端的 `127.0.0.1:22`** 再送进 vmess/tls:443 隧道 → 绕过 GFW
 * 对 :22 的限速,同时躲过「连节点自己 IP:22 触发自指防环 → 退化直连」的陷阱(见 [XrayConfig] 类注释)。
 *
 * 调用方拿到本地监听口后,让 sshj **直连** `127.0.0.1:<口>`(不再用 SocketFactory/SOCKS)。
 *
 * **xray-core 经 gomobile 产物 `xraybridge.aar` 反射调用**(见 `xray-bridge/`)。aar 不存在时
 * [available] 返回 false,[tunnel] 抛异常 → 调用方按"代理不可用 → 该 host 连接失败"处理,
 * **不影响直连 host**(SPEC §9 优雅降级)。这样未 build wrapper 也能正常编译运行(只是隧道功能不可用)。
 *
 * 一个 (proxy 名, override 目标) = 一个 xray 实例 + 一个本地端口,进程级常驻、按需惰性启动、幂等复用。
 */
object XrayProxy {

    private const val TAG = "XrayProxy"
    private const val BRIDGE_CLASS = "xraybridge.Xraybridge"

    private val lock = Any()
    /** 实例 key(proxy 名 + override 目标)→ 已分配的本地监听端口(已启动)。 */
    private val ports = HashMap<String, Int>()

    /** gomobile 产物在不在(决定隧道功能是否可用)。 */
    fun available(): Boolean = bridgeClass != null

    private val bridgeClass: Class<*>? by lazy {
        runCatching { Class.forName(BRIDGE_CLASS) }
            .onFailure { AppLog.i(TAG, "xraybridge.aar 未集成 → SSH-over-443 隧道不可用(直连 host 不受影响)") }
            .getOrNull()
    }

    /**
     * 确保「[proxy] 经隧道 override 到 [targetHost]:[targetPort]」的 xray 实例在跑,返回其**本地监听端口**。
     * sshj 直连 `127.0.0.1:<返回值>` 即等于连到隧道彼端的 [targetHost]:[targetPort]。
     * 幂等:同 (proxy, target) 复用。aar 缺失 / vmess 解析失败 / xray 启动失败 → 抛异常。
     *
     * 典型:[targetHost]=`127.0.0.1` + [targetPort]=22 → 连 vmess 节点服务端自己的 sshd(躲防环)。
     */
    fun tunnel(proxy: ProxyConfig, targetHost: String, targetPort: Int): Int = synchronized(lock) {
        val key = "${proxy.name}→$targetHost:$targetPort"
        ports[key]?.let { return it }
        val cls = bridgeClass ?: throw IllegalStateException("xraybridge.aar 未集成,SSH-over-443 不可用")

        val link = XrayConfig.parseVmess(proxy.url)
        // gomobile xray-core 内部 DNS 解析常超时(读不到 Android 系统 resolver)→ 用系统 resolver 先把
        // vmess 域名解析成 IP 传给 xray 拨号;SNI 仍用域名(TLS 证书校验)。已是 IP 则 getByName 原样返回。
        // 注:必在后台线程调用(本方法的三个调用点 SshConnection/HostClient/SshJump 都在后台)。
        val serverIp = runCatching { InetAddress.getByName(link.address).hostAddress }.getOrNull()
        val port = freeLocalPort()
        val config = XrayConfig.buildXrayConfig(link, port, targetHost, targetPort, serverIp)

        // gomobile:Go `func Start(key, cfg)` → Java static `Xraybridge.start(String,String)`(首字母小写)。
        val start = findMethod(cls, "start", String::class.java, String::class.java)
        start.invoke(null, key, config)   // 抛 InvocationTargetException(裹 Go error)即启动失败
        ports[key] = port
        AppLog.i(TAG, "xray 起 '$key' via ${link.address}${serverIp?.let { "[$it]" } ?: ""}:${link.port} → 本地 127.0.0.1:$port")
        return port
    }

    /** 关掉所有 xray 实例(Activity 销毁时调;幂等)。 */
    fun stopAll() = synchronized(lock) {
        val cls = bridgeClass ?: return
        val stop = runCatching { findMethod(cls, "stop", String::class.java) }.getOrNull()
        ports.keys.toList().forEach { key -> runCatching { stop?.invoke(null, key) } }
        ports.clear()
    }

    /** 系统分配一个空闲本地端口(开了立刻关,xray 随后 bind;窗口极小可接受)。 */
    private fun freeLocalPort(): Int =
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }

    /** gomobile 方法名通常首字母小写;兜底也试原名。 */
    private fun findMethod(cls: Class<*>, name: String, vararg params: Class<*>) =
        runCatching { cls.getMethod(name, *params) }
            .getOrElse { cls.getMethod(name.replaceFirstChar { c -> c.uppercase() }, *params) }
}
