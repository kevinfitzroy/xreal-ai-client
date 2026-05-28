package io.github.kevinfitzroy.xrealclient

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlin.concurrent.thread

/**
 * 主 Activity:WebView + xterm.js + SSH + VoiceDaemon。
 *
 * 启动顺序:
 *   1. 读 SettingsStore → 若 SshConfig 不全 → 跳 ConfigActivity
 *   2. 把 PEM 写 filesDir/ssh_key(perms 600)
 *   3. WebView 加载 terminal.html;先用 LocalEchoChannel 让 UI 立刻可交互
 *   4. 检查 RECORD_AUDIO 权限,未授予则 request
 *   5. 后台 connect SSH:成功 → swap channel(mutate bridge/daemon 字段,不重建)+ restart reader
 *
 * **关键不变量**:`TerminalBridge` 和 `VoiceDaemon` 实例从 onCreate 创建后**永不重建**。
 * Channel/Recorder/Asr 是 `@Volatile var` 字段,只 swap 不重建 ——
 * 因为 WebView 端 `window.Bridge` 在 loadUrl 时已经绑到了原 instance,
 * addJavascriptInterface runtime swap 在 JS 端无效。
 */
class MainActivity : Activity() {

    private lateinit var webView: WebView
    private lateinit var bridge: TerminalBridge
    private lateinit var voiceDaemon: VoiceDaemon
    private lateinit var store: SettingsStore
    private lateinit var sshConfig: SshConfig
    private lateinit var asrConfig: AsrConfig

    private var readerThread: Thread? = null
    @Volatile private var stopReader = false

    // 备路径 Ctrl+Alt+1/2 状态:记住启动 voice 的数字键 + 映射的 F13/F14
    private var backupVoiceDigit = -1
    private var backupVoiceKey = -1

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SettingsStore(this)
        sshConfig = store.loadSsh()
        asrConfig = store.loadAsr()

        // 1. 配置不全 → ConfigActivity
        if (!sshConfig.isComplete()) {
            startActivity(Intent(this, ConfigActivity::class.java))
            finish()
            return
        }

        window.setFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
        )
        WebView.setWebContentsDebuggingEnabled(true)

        // 2. PEM 写 filesDir(权限 600 — 跨用户隔离)
        val keyFile = filesDir.resolve("ssh_key")
        keyFile.writeText(sshConfig.privateKeyPem.trim() + "\n")
        keyFile.setReadable(false, false)
        keyFile.setReadable(true, true)
        val knownHostsFile = filesDir.resolve("known_hosts")

        // 3. 单 bridge/daemon 实例;先指向 LocalEchoChannel,SSH 连上后只 swap 字段
        val initialChannel: PtyChannel = LocalEchoChannel()
        bridge = TerminalBridge(initialChannel)

        webView = WebView(this).apply {
            setBackgroundColor(0xff11131a.toInt())
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
            }
            webViewClient = WebViewClient()
            addJavascriptInterface(bridge, TerminalBridge.JS_NAME)
        }
        setContentView(webView)
        webView.loadUrl("file:///android_asset/terminal.html")

        voiceDaemon = VoiceDaemon(
            webView = webView,
            initialChannel = initialChannel,
            initialAsr = buildAsr(asrConfig),
            initialRecorder = null,  // 等 4. 权限拿到
        )

        // 4. 麦克风权限
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) {
            voiceDaemon.recorder = AudioRecorder()
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
        }

        // 5. 后台 connect SSH
        thread(start = true, name = "ssh-connect", isDaemon = true) {
            connectSshAndStartReader(keyFile.absolutePath, knownHostsFile)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        if (requestCode == REQ_MIC) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                voiceDaemon.recorder = AudioRecorder()
            } else {
                Toast.makeText(this, R.string.mic_permission_denied, Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun connectSshAndStartReader(privateKeyPath: String, knownHosts: java.io.File) {
        runOnUiThread {
            webView.evaluateJavascript(
                "window.writeToTerm('${b64ansi("\r\n[33mConnecting SSH to ${sshConfig.host}…[0m\r\n")}')",
                null,
            )
        }
        val ssh = SshConnection(
            host = sshConfig.host,
            port = sshConfig.port,
            user = sshConfig.user,
            privateKeyPath = privateKeyPath,
            startupCommand = sshConfig.startupCommand,
            knownHostsFile = knownHosts,
        )
        try {
            ssh.connect(cols = 80, rows = 24)
            // 关闭旧 LocalEchoChannel(让旧 reader 的 read() 返回 -1 退出)
            val old = bridge.channel
            bridge.channel = ssh
            voiceDaemon.channel = ssh
            runCatching { old.close() }
            startReaderThread(ssh)
        } catch (e: Exception) {
            Log.w(TAG, "SSH connect failed: ${e.message}", e)
            runOnUiThread {
                webView.evaluateJavascript(
                    "window.writeToTerm('${b64ansi("\r\n[31mSSH 失败: ${e.message}[0m\r\n回退 LocalEcho 模式 (调 ConfigActivity 改配置)。\r\n")}')",
                    null,
                )
            }
            // 保持 LocalEchoChannel,reader 仍要起一下让 echo 通
            startReaderThread(bridge.channel)
        }
    }

    private fun buildAsr(c: AsrConfig): Asr = when {
        c.isVolcConfigured() -> VolcEngineAsr(
            appid = c.appid, token = c.token,
            cluster = c.cluster.ifBlank { "volcengine_input_common" },
        )
        else -> MockAsr()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!::voiceDaemon.isInitialized) return super.dispatchKeyEvent(event)

        // 诊断:打印每个到达的 keycode(确认 8BitDo F13/F14 是否被收到 = Stage A.1)
        Log.i(TAG, "dispatchKey code=${event.keyCode} action=${event.action} ctrl=${event.isCtrlPressed} alt=${event.isAltPressed}")

        // 备路径 Ctrl+Alt+1/2 → F13/F14。
        // 注意:松手时 ctrl/alt 通常先于数字键释放,所以数字键 UP 到达时 isCtrlPressed 已 false。
        // 解法:DOWN(带 ctrl+alt)时记住"数字键→voice key"映射,对应数字键的 UP(忽略修饰键)结束。
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0
            && event.isCtrlPressed && event.isAltPressed
        ) {
            val mapped = when (event.keyCode) {
                KeyEvent.KEYCODE_1 -> VoiceDaemon.KEY_F13
                KeyEvent.KEYCODE_2 -> VoiceDaemon.KEY_F14
                else -> null
            }
            if (mapped != null) {
                backupVoiceDigit = event.keyCode
                backupVoiceKey = mapped
                voiceDaemon.onKeyDown(mapped)
                return true
            }
        }
        if (event.action == KeyEvent.ACTION_UP && event.keyCode == backupVoiceDigit) {
            voiceDaemon.onKeyUp(backupVoiceKey)
            backupVoiceDigit = -1
            return true
        }
        if (event.keyCode == VoiceDaemon.KEY_F13 || event.keyCode == VoiceDaemon.KEY_F14) {
            routeVoiceKey(event.action, event.keyCode); return true
        }
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_ENTER -> if (voiceDaemon.onEnter()) return true
                KeyEvent.KEYCODE_ESCAPE -> if (voiceDaemon.onEsc()) return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun routeVoiceKey(action: Int, keyCode: Int) {
        when (action) {
            KeyEvent.ACTION_DOWN -> voiceDaemon.onKeyDown(keyCode)
            KeyEvent.ACTION_UP -> voiceDaemon.onKeyUp(keyCode)
        }
    }

    private fun startReaderThread(ch: PtyChannel) {
        // 停旧 reader(close 旧 channel 会让旧 reader 的 read 抛 / 返回 -1)
        stopReader = true
        readerThread?.interrupt()
        stopReader = false
        readerThread = thread(start = true, name = "pty-reader", isDaemon = true) {
            val buf = ByteArray(4096)
            try {
                val ins = ch.inputStream()
                while (!stopReader) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    val b64 = Base64.encodeToString(buf, 0, n, Base64.NO_WRAP)
                    runOnUiThread {
                        webView.evaluateJavascript("window.writeToTerm('$b64')", null)
                    }
                }
            } catch (e: Exception) {
                if (!stopReader) Log.w(TAG, "pty-reader stopped: ${e.message}")
            }
        }
    }

    private fun b64ansi(s: String): String =
        Base64.encodeToString(s.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)

    override fun onDestroy() {
        stopReader = true
        if (::voiceDaemon.isInitialized) voiceDaemon.shutdown()
        if (::bridge.isInitialized) runCatching { bridge.channel.close() }
        readerThread?.interrupt()
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "MainActivity"
        private const val REQ_MIC = 0x101
    }
}
