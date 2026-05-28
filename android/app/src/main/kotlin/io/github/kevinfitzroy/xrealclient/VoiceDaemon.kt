package io.github.kevinfitzroy.xrealclient

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.webkit.WebView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Phase 0.6 骨架:状态机 + overlay 控制 + 文本注入。
 *
 * 真实路径(Stage B 之后):
 *   F13/F14 down → AudioRecord 开始 → Opus 编码缓冲
 *   F13/F14 up   → 停录 → 豆包 ASR HTTP/WS → 文本回来
 *   Enter        → 文本写 channel.outputStream() → IDLE
 *   Esc          → 取消 → IDLE
 *
 * Phase 0.6 mock:跳过 AudioRecord / 豆包,ASR 用 [MockAsr] 直接返回固定串。
 * 验证目的:状态机迁移 + overlay show/hide + Enter 路径(byte 写到 PtyChannel)。
 *
 * keycode:
 *   F13 (zh) = 326,F14 (en) = 327。Stage A.1 真机验证 8BitDo Micro 是否真发这俩。
 *   备路径:Ctrl+Alt+1/2(待 0.7 加)。
 */
class VoiceDaemon(
    private val webView: WebView,
    initialChannel: PtyChannel,
    initialAsr: Asr = MockAsr(),
    initialRecorder: AudioRecorder? = null,
    private val mainHandler: Handler = Handler(Looper.getMainLooper()),
) {
    // 这三个字段允许 MainActivity 在 runtime swap(SSH connect / RECORD_AUDIO 权限拿到 / config 改 ASR)。
    // 不重建 VoiceDaemon —— 重建会丢状态、且没必要。
    @Volatile var channel: PtyChannel = initialChannel
    @Volatile var asr: Asr = initialAsr
    /** null = 没有麦克风权限或 mock 模式;录音逻辑跳过,ASR 拿空 bytes(MockAsr 不影响,Volc 直接返回空) */
    @Volatile var recorder: AudioRecorder? = initialRecorder

    enum class State { IDLE, RECORDING, ASR_PENDING, PREVIEW }

    @Volatile private var state: State = State.IDLE
    @Volatile private var currentText: String? = null

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var asrJob: Job? = null

    fun currentState(): State = state

    /** 按键路由从 dispatchKeyEvent 进来。这里只处理 F13/F14;Enter/Esc 走 [onEnter]/[onEsc]。 */
    fun onKeyDown(keyCode: Int) {
        if (keyCode != KEY_F13 && keyCode != KEY_F14) return
        val lang = if (keyCode == KEY_F13) "zh" else "en"
        // 任意状态按 F13/F14 都是"开始(重新)录音"
        asrJob?.cancel()
        recorder?.cancel()  // 取消之前可能在跑的录音
        currentText = null
        state = State.RECORDING
        showOverlay("🎤 录音中… (${lang})", "")
        recorder?.start()
        Log.d(TAG, "RECORDING start lang=$lang recorder=${recorder != null}")
    }

    fun onKeyUp(keyCode: Int) {
        if (keyCode != KEY_F13 && keyCode != KEY_F14) return
        if (state != State.RECORDING) return
        val lang = if (keyCode == KEY_F13) "zh" else "en"
        val audio = recorder?.stop() ?: ByteArray(0)
        state = State.ASR_PENDING
        showOverlay("识别中…", "")
        asrJob = scope.launch {
            val text = asr.recognize(audio, lang)
            if (state == State.ASR_PENDING) {  // 没被取消
                currentText = text
                state = if (text.isBlank()) State.IDLE else State.PREVIEW
                if (text.isBlank()) hideOverlay()
                else showOverlay("🎤 已识别", text)
                Log.d(TAG, "PREVIEW text='$text'")
            }
        }
    }

    /** @return true = overlay 接管 Enter(写文本);false = 透传到 WebView/xterm */
    fun onEnter(): Boolean {
        if (state != State.PREVIEW) return false
        val text = currentText ?: run { resetIdle(); return false }
        try {
            channel.outputStream().write(text.toByteArray(Charsets.UTF_8))
            channel.outputStream().flush()
        } catch (e: Exception) {
            Log.w(TAG, "write injected text failed: ${e.message}")
        }
        resetIdle()
        return true
    }

    /** @return true = 拦截(取消录音/preview);false = 透传 */
    fun onEsc(): Boolean {
        if (state == State.IDLE) return false
        asrJob?.cancel()
        recorder?.cancel()
        resetIdle()
        Log.d(TAG, "ESC cancel")
        return true
    }

    fun shutdown() {
        scope.cancel()
        hideOverlay()
    }

    private fun resetIdle() {
        state = State.IDLE
        currentText = null
        hideOverlay()
    }

    private fun showOverlay(status: String, text: String) {
        val s = JSONObject.quote(status)
        val t = JSONObject.quote(text)
        mainHandler.post {
            webView.evaluateJavascript("window.showOverlay($s, $t)", null)
        }
    }

    private fun hideOverlay() {
        mainHandler.post {
            webView.evaluateJavascript("window.hideOverlay()", null)
        }
    }

    companion object {
        private const val TAG = "VoiceDaemon"
        /** KEYCODE_F13 raw int(API 36 引入 KEYCODE_F13 = 326 常量,这里直接写数字保持跨版本) */
        const val KEY_F13 = 326
        const val KEY_F14 = 327
    }
}

/**
 * ASR 抽象。audio 是 WAV bytes(16kHz mono PCM_16BIT + 44 byte header);
 * mock 实现可以忽略。
 */
interface Asr {
    /** @param lang "zh" 或 "en";@param audio WAV bytes(mock 可忽略) */
    suspend fun recognize(audio: ByteArray, lang: String): String
}

/** Phase 0.6 mock — 不调 API,直接返回固定串。500ms 模拟网络延迟。 */
class MockAsr : Asr {
    override suspend fun recognize(audio: ByteArray, lang: String): String {
        delay(500)
        return when (lang) {
            "zh" -> "ls -la\n"
            "en" -> "pwd\n"
            else -> "echo mock\n"
        }
    }
}
