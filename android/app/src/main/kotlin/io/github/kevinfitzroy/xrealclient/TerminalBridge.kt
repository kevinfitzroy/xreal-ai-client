package io.github.kevinfitzroy.xrealclient

import android.util.Base64
import android.util.Log
import android.webkit.JavascriptInterface

/**
 * JS↔Kotlin 桥接。WebView 端通过 `window.Bridge.onInput(...)` / `onResize(...)` 调用。
 *
 * 编码:bytes 走 Base64(URL/特殊字符安全)。性能足够 SSH < 100 KB/s。
 * Stage A.3 如果发现大输出场景卡顿,fallback 到 localhost WebSocket(~30 行切换)。
 *
 * 注意:@JavascriptInterface 方法在 WebView 的 IO 线程(非 main),
 * 直接写 PtyChannel 的 outputStream 安全(sshj / PipedStream 都是线程安全的)。
 */
class TerminalBridge(
    initial: PtyChannel,
    /** JS 列表页 Enter 进入某 project 时回调(host, name, type)→ Activity 切到终端视图 */
    private val onOpenProject: (host: String, name: String, type: String) -> Unit = { _, _, _ -> },
    /** 虚拟键盘 / 语音键:down=按下开始录音,up=松开识别。lang = "zh"|"en" */
    private val onVoice: (down: Boolean, lang: String) -> Unit = { _, _ -> },
    /** 虚拟 Enter(voice-aware:preview 时发送识别文本,否则当普通回车) */
    private val onVkeyEnter: () -> Unit = {},
    /** 虚拟 Esc(voice-aware:取消录音/preview,否则发 ESC) */
    private val onVkeyEsc: () -> Unit = {},
    /** 是否有外接物理键盘(决定 JS 要不要显示自绘虚拟键盘) */
    private val hasHwKeyboard: () -> Boolean = { false },
) {

    /**
     * 可变 channel:WebView 在初次 loadUrl 时已经把 `window.Bridge` 绑到了这个 instance,
     * 之后再 addJavascriptInterface 是无效的(JS 端代理不重新绑定)。
     * 所以 channel swap(LocalEcho → SSH)通过改这个字段实现,JS 端无感。
     */
    @Volatile var channel: PtyChannel = initial

    @JavascriptInterface
    fun openProject(host: String, name: String, type: String) {
        onOpenProject(host, name, type)
    }

    @JavascriptInterface fun voiceDown(lang: String) = onVoice(true, lang)
    @JavascriptInterface fun voiceUp(lang: String) = onVoice(false, lang)
    @JavascriptInterface fun vkeyEnter() = onVkeyEnter()
    @JavascriptInterface fun vkeyEsc() = onVkeyEsc()
    @JavascriptInterface fun hasHardwareKeyboard(): Boolean = hasHwKeyboard()

    @JavascriptInterface
    fun onInput(b64: String) {
        try {
            val bytes = Base64.decode(b64, Base64.NO_WRAP)
            val ch = channel
            ch.outputStream().write(bytes)
            ch.outputStream().flush()
        } catch (e: Exception) {
            Log.w(TAG, "onInput failed: ${e.message}")
        }
    }

    @JavascriptInterface
    fun onResize(cols: Int, rows: Int) {
        try {
            channel.resize(cols, rows)
        } catch (e: Exception) {
            Log.w(TAG, "onResize($cols, $rows) failed: ${e.message}")
        }
    }

    companion object {
        const val TAG = "TerminalBridge"
        /** WebView 端访问的全局名:`window.Bridge` */
        const val JS_NAME = "Bridge"
    }
}
