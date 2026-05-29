package io.github.kevinfitzroy.xrealclient

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.WebView
import org.json.JSONObject

/**
 * 语音输入状态机(真流式):按住说话,边录边传,识别结果实时上屏。
 *
 *   F13/F14 down → 开 ASR 会话(连 WS)+ 开录音,PCM chunk 实时喂入 → state STREAMING
 *   识别中间结果 → onPartial → 实时刷 overlay(全量文本替换)
 *   F13/F14 up   → 停录 + 发最后一包(负包) → state ASR_PENDING(等最终结果补包)
 *   onFinal      → state PREVIEW(等用户确认)
 *   Enter        → 把文本写 channel.outputStream() → IDLE(不 auto-\n:语音误识安全网,再按 Enter 才执行)
 *   Esc / 重按   → 取消会话 → IDLE
 *
 * **late-callback race**:重按 / 取消后旧 WS reader 线程可能还喷 partial。两层防御 ——
 * generation counter([asrGen],与 [ManifestFetcher] 同套路)+ [VolcEngineAsr] 内部 cancelled flag。
 *
 * keycode:F13 (zh) = 326,F14 (en) = 327。虚拟语音键经 bridge 直接调 [onKeyDown]/[onKeyUp]
 * (不经 OS 输入层,绕开 F13 KeyEvent 投递问题);物理键经 dispatchKeyEvent 进来。
 */
class VoiceDaemon(
    private val webView: WebView,
    initialChannel: PtyChannel,
    initialAsr: Asr = MockAsr(),
    initialRecorder: AudioRecorder? = null,
    private val mainHandler: Handler = Handler(Looper.getMainLooper()),
) {
    // MainActivity 在 runtime swap(SSH connect / 麦克风权限 / config 改 ASR)。不重建 VoiceDaemon。
    @Volatile var channel: PtyChannel = initialChannel
    @Volatile var asr: Asr = initialAsr
    @Volatile var recorder: AudioRecorder? = initialRecorder
    /** 当前 project 的语音热词(进 project 时 MainActivity 设;默认 = 继承的 [Hotwords.BASE])。 */
    @Volatile var hotwords: List<String> = Hotwords.BASE
    /**
     * 注入语音文本时是否加 [VOICE_MARKER] 前缀。仅 AI-agent 类 project 开(让接收端 Claude Code
     * 知道"这条是语音、按意图纠错",配合 sub-project CLAUDE.md 的常驻指导)。
     * 普通 SSH shell **必须** false —— 前缀打进 bash 就是废命令。
     */
    @Volatile var voiceMarkerEnabled: Boolean = false

    enum class State { IDLE, STREAMING, ASR_PENDING, PREVIEW }

    @Volatile private var state: State = State.IDLE
    @Volatile private var currentText: String? = null
    @Volatile private var stream: AsrStream? = null
    /** 会话代数:每次 onKeyDown/onEsc ++,回调凭捕获的 gen 比对,过滤上一个会话的迟到回调。 */
    @Volatile private var asrGen = 0

    fun currentState(): State = state

    fun onKeyDown(keyCode: Int) {
        if (keyCode != KEY_F13 && keyCode != KEY_F14) return
        val lang = if (keyCode == KEY_F13) "zh" else "en"

        asrGen++
        val gen = asrGen
        stream?.cancel()
        recorder?.cancel()
        currentText = null
        state = State.STREAMING
        showOverlay("🎤 聆听中…", "")

        val cb = object : AsrCallback {
            override fun onPartial(text: String) = onAsrPartial(gen, text)
            override fun onFinal(text: String) = onAsrFinal(gen, text)
            override fun onError(reason: String) = onAsrError(gen, reason)
        }
        stream = asr.open(lang, hotwords, cb)
        recorder?.start { chunk -> if (gen == asrGen) stream?.send(chunk) }
        Log.d(TAG, "STREAMING start lang=$lang recorder=${recorder != null} hotwords=${hotwords.size}")
    }

    fun onKeyUp(keyCode: Int) {
        if (keyCode != KEY_F13 && keyCode != KEY_F14) return
        if (state != State.STREAMING) return
        recorder?.stop()      // 停止采集,冲出尾块
        stream?.finish()      // 发最后一包(负包),等最终结果
        state = State.ASR_PENDING
        showOverlay("识别中…", currentText ?: "")
    }

    private fun onAsrPartial(gen: Int, text: String) {
        if (gen != asrGen) return
        if (state != State.STREAMING && state != State.ASR_PENDING) return
        currentText = text
        val status = if (state == State.STREAMING) "🎤 聆听中…" else "识别中…"
        showOverlay(status, text)
    }

    private fun onAsrFinal(gen: Int, text: String) {
        if (gen != asrGen) return
        if (state != State.STREAMING && state != State.ASR_PENDING) return
        if (text.isBlank()) {
            resetIdle()
        } else {
            currentText = text
            state = State.PREVIEW
            showOverlay("🎤 已识别", text)
        }
        Log.d(TAG, "FINAL text='$text'")
    }

    private fun onAsrError(gen: Int, reason: String) {
        if (gen != asrGen) return
        Log.w(TAG, "ASR error: $reason")
        resetIdle()
    }

    /** @return true = overlay 接管 Enter(写文本);false = 透传到 WebView/xterm */
    fun onEnter(): Boolean {
        if (state != State.PREVIEW) return false
        val text = currentText ?: run { resetIdle(); return false }
        val payload = if (voiceMarkerEnabled) VOICE_MARKER + text else text
        try {
            channel.outputStream().write(payload.toByteArray(Charsets.UTF_8))
            channel.outputStream().flush()
        } catch (e: Exception) {
            Log.w(TAG, "write injected text failed: ${e.message}")
        }
        resetIdle()
        return true
    }

    /** @return true = 拦截(取消会话/preview);false = 透传 */
    fun onEsc(): Boolean {
        if (state == State.IDLE) return false
        asrGen++              // 作废当前会话的迟到回调
        stream?.cancel()
        recorder?.cancel()
        resetIdle()
        Log.d(TAG, "ESC cancel")
        return true
    }

    fun shutdown() {
        asrGen++
        stream?.cancel()
        recorder?.cancel()
        hideOverlay()
    }

    private fun resetIdle() {
        state = State.IDLE
        currentText = null
        stream = null
        hideOverlay()
    }

    private fun showOverlay(status: String, text: String) {
        val s = JSONObject.quote(status)
        val t = JSONObject.quote(text)
        mainHandler.post { webView.evaluateJavascript("window.showOverlay($s, $t)", null) }
    }

    private fun hideOverlay() {
        mainHandler.post { webView.evaluateJavascript("window.hideOverlay()", null) }
    }

    companion object {
        private const val TAG = "VoiceDaemon"
        const val KEY_F13 = 326
        const val KEY_F14 = 327
        /** 注入 AI-agent 会话时的语音前缀。与 sub-project CLAUDE.md 的约定一致(见 orchestrator-CLAUDE.md)。 */
        const val VOICE_MARKER = "🎤 "
    }
}

/**
 * 流式 ASR 抽象。一次"按住说话"对应一个 [AsrStream] 会话。
 * 回调可能在任意线程(WS reader / 定时器),实现方保证线程安全;UI marshal 由调用方负责。
 */
interface Asr {
    /** 开会话。[lang] "zh"/"en"(部分实现自动判语种则忽略);[hotwords] 提升识别准确率(可空)。 */
    fun open(lang: String, hotwords: List<String>, callback: AsrCallback): AsrStream
}

interface AsrStream {
    /** 实时音频块(裸 PCM16LE 16k mono)。 */
    fun send(pcmChunk: ByteArray)
    /** 录音结束:发最后一包(负包),触发最终结果。 */
    fun finish()
    /** 取消:关连接,之后不再回调。 */
    fun cancel()
}

/** 回调可能在任意线程。[onPartial] 携带全量文本(可直接替换显示)。 */
interface AsrCallback {
    fun onPartial(text: String)
    fun onFinal(text: String)
    fun onError(reason: String)
}

/** emulator / 无凭证:假装流式 —— 300ms 出 partial,finish 后 300ms 出 final。忽略真实音频。 */
class MockAsr : Asr {
    override fun open(lang: String, hotwords: List<String>, callback: AsrCallback): AsrStream = object : AsrStream {
        private val handler = Handler(Looper.getMainLooper())
        @Volatile private var cancelled = false
        private val text = if (lang == "en") "pwd" else "ls -la"

        init {
            handler.postDelayed({ if (!cancelled) callback.onPartial(text) }, 300)
        }

        override fun send(pcmChunk: ByteArray) {}
        override fun finish() {
            handler.postDelayed({ if (!cancelled) callback.onFinal(text) }, 300)
        }
        override fun cancel() {
            cancelled = true
            handler.removeCallbacksAndMessages(null)
        }
    }
}
