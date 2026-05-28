package io.github.kevinfitzroy.xrealclient

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle
import android.text.InputType
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlin.concurrent.thread

/**
 * 主 Activity — WebView SPA:列表视图(Agent Deck)⇄ 终端视图。
 *
 * 当前(P.1):列表用 mock 数据;进入 project 切到终端,终端走 LocalEchoChannel
 * (真 SSH per-project 连接 + 状态探测后续接)。
 *
 * 导航:
 *   列表 Enter → JS Bridge.openProject → 切终端视图
 *   BACK 键   → 终端视图返回列表;列表视图则退出 app
 *
 * **不变量**:TerminalBridge / VoiceDaemon 实例创建后不重建(channel 等用 @Volatile var 热切)。
 */
class MainActivity : Activity() {

    private lateinit var webView: WebView
    private lateinit var bridge: TerminalBridge
    private lateinit var voiceDaemon: VoiceDaemon
    private val channel: PtyChannel = LocalEchoChannel()

    private enum class View { LIST, TERMINAL }
    @Volatile private var view = View.LIST

    private var readerThread: Thread? = null
    @Volatile private var stopReader = false

    private var backupVoiceDigit = -1
    private var backupVoiceKey = -1

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
        )
        // 彻底禁用系统软键盘:窗口声明"不需要与 IME 交互"(仍可聚焦、硬件键正常)。
        // 输入只走 8BitDo 硬件键 + 语音 + 自绘虚拟键盘。比 per-view TYPE_NULL 可靠。
        window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        WebView.setWebContentsDebuggingEnabled(true)

        bridge = TerminalBridge(
            initial = channel,
            onOpenProject = ::onOpenProject,
            onVoice = { down, lang ->
                val kc = if (lang == "en") VoiceDaemon.KEY_F14 else VoiceDaemon.KEY_F13
                if (down) voiceDaemon.onKeyDown(kc) else voiceDaemon.onKeyUp(kc)
            },
            onVkeyEnter = { if (!voiceDaemon.onEnter()) writeChannelByte(13) },   // 13 = CR
            onVkeyEsc = { if (!voiceDaemon.onEsc()) writeChannelByte(27) },        // 27 = ESC
            hasHwKeyboard = ::hasHardwareKeyboard,
            onGoHome = { if (view == View.TERMINAL) backToList() },
        )

        webView = object : WebView(this@MainActivity) {
            // 抑制软键盘:本产品输入 = 8BitDo 硬件键 + 语音,软键盘会挡住半屏。
            // TYPE_NULL 让系统不弹软键盘,但硬件 KeyEvent 仍照常进 dispatchKeyEvent / WebView。
            override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
                val ic = super.onCreateInputConnection(outAttrs)
                outAttrs.inputType = InputType.TYPE_NULL
                return ic
            }
        }.apply {
            setBackgroundColor(0xff0d0f16.toInt())
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
            }
            webViewClient = WebViewClient()
            addJavascriptInterface(bridge, TerminalBridge.JS_NAME)
        }
        setContentView(webView)
        webView.loadUrl("file:///android_asset/index.html")

        voiceDaemon = VoiceDaemon(webView = webView, initialChannel = channel)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) {
            voiceDaemon.recorder = AudioRecorder()
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
        }

        startReaderThread()
    }

    /** JS 列表 Enter 进入 project(当前 mock:仅切视图;真 SSH 连接后续接) */
    private fun onOpenProject(host: String, name: String, type: String) {
        Log.i(TAG, "openProject host=$host name=$name type=$type")
        view = View.TERMINAL
        runOnUiThread {
            val n = org.json.JSONObject.quote(name)
            val t = org.json.JSONObject.quote(type)
            webView.evaluateJavascript("window.showTerminal($n, $t)", null)
        }
        // TODO(状态探测/真SSH):按 host+name 查配置 → SshConnection.connect → bridge.channel = ssh
    }

    private fun backToList() {
        view = View.LIST
        runOnUiThread { webView.evaluateJavascript("window.showList()", null) }
    }

    private fun writeChannelByte(b: Int) {
        runCatching { channel.outputStream().write(b); channel.outputStream().flush() }
    }

    /** 是否接了外置物理键盘(8BitDo 在键盘模式会算 QWERTY)→ 决定虚拟键盘显隐 */
    private fun hasHardwareKeyboard(): Boolean {
        val cfg = resources.configuration
        return cfg.keyboard == android.content.res.Configuration.KEYBOARD_QWERTY &&
            cfg.hardKeyboardHidden == android.content.res.Configuration.HARDKEYBOARDHIDDEN_NO
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode == REQ_MIC) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) voiceDaemon.recorder = AudioRecorder()
            else Toast.makeText(this, R.string.mic_permission_denied, Toast.LENGTH_LONG).show()
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!::voiceDaemon.isInitialized) return super.dispatchKeyEvent(event)

        // BACK:终端视图 → 返回列表(消费);列表视图 → 默认(退出)
        if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
            if (view == View.TERMINAL) { backToList(); return true }
            return super.dispatchKeyEvent(event)
        }

        // 列表视图:方向键/Enter 交给 WebView 的列表导航,语音键不介入
        if (view == View.LIST) return super.dispatchKeyEvent(event)

        // --- 以下为终端视图 ---
        Log.i(TAG, "dispatchKey code=${event.keyCode} action=${event.action} ctrl=${event.isCtrlPressed} alt=${event.isAltPressed}")

        // 备路径 Ctrl+Alt+1/2 → F13/F14(松手时修饰键先释放,所以记住数字键的 UP 来收尾)
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 && event.isCtrlPressed && event.isAltPressed) {
            val mapped = when (event.keyCode) {
                KeyEvent.KEYCODE_1 -> VoiceDaemon.KEY_F13
                KeyEvent.KEYCODE_2 -> VoiceDaemon.KEY_F14
                else -> null
            }
            if (mapped != null) { backupVoiceDigit = event.keyCode; backupVoiceKey = mapped; voiceDaemon.onKeyDown(mapped); return true }
        }
        if (event.action == KeyEvent.ACTION_UP && event.keyCode == backupVoiceDigit) {
            voiceDaemon.onKeyUp(backupVoiceKey); backupVoiceDigit = -1; return true
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

    private fun startReaderThread() {
        stopReader = false
        readerThread = thread(start = true, name = "pty-reader", isDaemon = true) {
            val buf = ByteArray(4096)
            try {
                val ins = channel.inputStream()
                while (!stopReader) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    val b64 = Base64.encodeToString(buf, 0, n, Base64.NO_WRAP)
                    runOnUiThread { webView.evaluateJavascript("window.writeToTerm('$b64')", null) }
                }
            } catch (e: Exception) {
                if (!stopReader) Log.w(TAG, "pty-reader stopped: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        stopReader = true
        if (::voiceDaemon.isInitialized) voiceDaemon.shutdown()
        runCatching { channel.close() }
        readerThread?.interrupt()
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "MainActivity"
        private const val REQ_MIC = 0x101
    }
}
