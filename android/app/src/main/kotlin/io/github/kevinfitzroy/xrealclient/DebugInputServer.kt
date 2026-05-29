package io.github.kevinfitzroy.xrealclient

import android.util.Log
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * 调试期"电脑打字直通手机终端"的接收端 —— localhost TCP server,把收到的裸字节当作终端输入
 * 写进当前活动 channel(等价于在手机上敲键)。配合 Mac 侧 `scripts/term-relay.py` + `adb forward`。
 *
 * 安全:**只在 debug build + 有 host 配置时才起**(见 MainActivity),绑定 127.0.0.1,单连接。
 * 生产/未配置场景根本不监听。adb forward 的链路只有 USB 接入者能用。
 */
class DebugInputServer(
    private val port: Int = 8889,
    /** 取当前活动 channel(用户切 project 时引用会变,故每次现取)。 */
    private val sink: () -> PtyChannel,
) {
    @Volatile private var running = false
    private var server: ServerSocket? = null

    fun start() {
        if (running) return
        running = true
        thread(isDaemon = true, name = "dbg-input") {
            try {
                val s = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress("127.0.0.1", port))
                }
                server = s
                Log.i(TAG, "调试输入直通监听 127.0.0.1:$port(adb forward 后电脑可打字进终端)")
                while (running) {
                    val sock = try { s.accept() } catch (e: Exception) { break }
                    handle(sock)   // 单连接:handle 阻塞到断开,再 accept 下一个
                }
            } catch (e: Exception) {
                Log.w(TAG, "input server 退出: ${e.message}")
            }
        }
    }

    private fun handle(sock: Socket) {
        try {
            sock.use {
                if (sink() is LocalEchoChannel) {
                    runCatching {
                        it.getOutputStream().write("# 当前是本地 echo —— 请先在手机上进入一个 project 终端\r\n".toByteArray())
                        it.getOutputStream().flush()
                    }
                }
                val ins = it.getInputStream()
                val buf = ByteArray(1024)
                while (running) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    // 每次现取活动 channel:用户中途切了 project 也跟得上;写已关闭的 channel 抛异常 → 外层静默
                    sink().write(buf.copyOf(n))   // 原子 write+flush(串行化,见 PtyChannel)
                }
            }
        } catch (e: Exception) {
            Log.i(TAG, "input 连接结束: ${e.message}")   // channel 关了/客户端断了 → 静默,等下个连接
        }
    }

    fun stop() {
        running = false
        runCatching { server?.close() }
    }

    companion object {
        private const val TAG = "DebugInputServer"
    }
}
