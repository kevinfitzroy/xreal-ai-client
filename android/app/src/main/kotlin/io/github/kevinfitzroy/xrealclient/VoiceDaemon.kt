package io.github.kevinfitzroy.xrealclient

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.WebView
import org.json.JSONObject
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.Executors

/**
 * 语音输入状态机(真流式):按住说话,边录边传,识别结果实时上屏。
 *
 *   F13/F14 down → 开 ASR 会话(连 WS)+ 开录音,PCM chunk 实时喂入 → state STREAMING
 *   识别中间结果 → onPartial → 实时刷 overlay(全量文本替换)
 *   F13/F14 up   → 停录 + 发最后一包(负包) → state ASR_PENDING(等最终结果补包)
 *   onFinal      → state PREVIEW(等用户确认)
 *   Enter        → 把文本写 channel.write() → IDLE(不 auto-\n:语音误识安全网,再按 Enter 才执行)
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

    // ── LLM 上下文纠错(issue #16)。corrector==null → 纠错关闭,行为同改造前 ───────────────────
    /** 纠错引擎(未配置 = null → 跳过纠错直接 PREVIEW)。MainActivity 启动按 [CorrectionConfig] 注入。 */
    @Volatile var corrector: VoiceCorrector? = null
    /** 终端背景来源(tmux capture-pane)。MainActivity 在 [switchTo] 按是否真 SSH 注入;LocalEcho=null。 */
    @Volatile var contextSource: TerminalContextSource? = null
    /** 当前 project 显示名 / session 类型,喂给纠错 prompt(applyProjectHotwords 设)。 */
    @Volatile var projectName: String = ""
    @Volatile var sessionType: String = "ssh"

    enum class State { IDLE, STREAMING, ASR_PENDING, CORRECTING, PREVIEW }

    @Volatile private var state: State = State.IDLE
    @Volatile private var currentText: String? = null
    @Volatile private var stream: AsrStream? = null
    /** 当前会话语种(onKeyDown 设),纠错 prompt 用(提示别跨语种乱译)。 */
    @Volatile private var lang: String = "zh"
    /** 最近已确认注入的语音指令(最新在 first),给纠错 prompt 连续指令上下文。 */
    private val recentCommands = ConcurrentLinkedDeque<String>()
    /** 纠错跑在单独后台线程:含 tmux 抓取(SSH I/O)+ LLM HTTP,绝不在回调/主线程跑。 */
    private val correctExec = Executors.newSingleThreadExecutor { r -> Thread(r, "voice-correct").apply { isDaemon = true } }
    /** 会话代数:每次 onKeyDown/onEsc ++,回调凭捕获的 gen 比对,过滤上一个会话的迟到回调。 */
    @Volatile private var asrGen = 0

    fun currentState(): State = state

    fun onKeyDown(keyCode: Int) {
        if (keyCode != KEY_F13 && keyCode != KEY_F14) return
        val lang = if (keyCode == KEY_F13) "zh" else "en"
        this.lang = lang

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
        recorder?.stop()      // 总是停采集(防 mic 卡死:即便 state 已被服务端回调提前改动)
        if (state != State.STREAMING) return
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
        Log.d(TAG, "FINAL text='$text'")
        if (text.isBlank()) { resetIdle(); return }
        currentText = text

        val corrector = this.corrector
        if (corrector == null) {           // 纠错关闭:直接预览(改造前行为)
            state = State.PREVIEW
            showOverlay("🎤 已识别", text)
            return
        }

        // 纠错开启:进 CORRECTING,后台抓 tmux 上下文 + 跑 LLM,完成回 PREVIEW(失败回退原文)。
        // gen 守卫:期间用户重按/Esc 会 ++asrGen,迟到的纠错结果被丢弃。
        state = State.CORRECTING
        showOverlayCorrecting(text)   // 转圈动画 + 原文灰显 + "稍候"提示(overlay 自管 CSS spinner)
        correctExec.execute {
            val ctx = buildContext()
            val corrected = runCatching { corrector.correct(text, ctx) }.getOrDefault(text)
            mainHandler.post {
                if (gen != asrGen || state != State.CORRECTING) return@post   // 已取消/被新会话取代
                currentText = corrected
                state = State.PREVIEW
                val tag = if (corrected != text) "✨ 已纠错" else "🎤 已识别"
                showOverlay(tag, corrected)
            }
        }
    }

    /** 预热纠错连接(进 project 时由 MainActivity 调):后台建好到 LLM 的 TLS 连接,首次纠错不付握手。 */
    fun prewarmCorrector() {
        val c = corrector ?: return
        correctExec.execute { runCatching { c.prewarm() } }
    }

    /** 组装纠错背景信息(在 voice-correct 后台线程调:含 tmux SSH 抓取)。 */
    private fun buildContext(): VoiceContext {
        val tail = runCatching { contextSource?.snapshot() }.getOrNull()
        return VoiceContext(
            projectName = projectName,
            sessionType = sessionType,
            isAiAgent = voiceMarkerEnabled,   // = AI-agent 类(applyProjectHotwords 同源设)
            hotwords = Hotwords.forCorrection(hotwords),   // ASR 热词 + LLM 大词表(GLOSSARY);ASR 路径仍用小表
            lang = lang,
            terminalTail = tail?.takeIf { it.isNotBlank() },
            recentCommands = recentCommands.toList(),
        )
    }

    private fun onAsrError(gen: Int, reason: String) {
        if (gen != asrGen) return
        AppLog.w(TAG, "ASR error: $reason")
        resetIdle()
    }

    /** @return true = overlay 接管 Enter(写文本);false = 透传到 WebView/xterm */
    fun onEnter(): Boolean {
        // 纠错进行中按 Enter:拦截但不动作(别让这个 CR 漏进 shell);等纠错完成进 PREVIEW 再按。
        if (state == State.CORRECTING) return true
        if (state != State.PREVIEW) return false
        val text = currentText ?: run { resetIdle(); return false }
        // 首字符是 ! / 时不加 🎤:! = 直接执行 bash,/ = Claude Code 内置命令;加了前缀这俩都会被当成普通文本而非命令。
        val isCommand = text.firstOrNull().let { it == '!' || it == '/' }
        val payload = if (voiceMarkerEnabled && !isCommand) VOICE_MARKER + text else text
        try {
            channel.write(payload.toByteArray(Charsets.UTF_8))   // 原子 write+flush(串行化,见 PtyChannel)
            recordRecent(text)   // 进纠错 prompt 的"最近指令"上下文
        } catch (e: Exception) {
            AppLog.w(TAG, "write injected text failed: ${e.javaClass.simpleName}: ${e.message}")
        }
        resetIdle()
        return true
    }

    private fun recordRecent(text: String) {
        recentCommands.addFirst(text)
        while (recentCommands.size > RECENT_MAX) recentCommands.removeLast()
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

    /** 纠错中专用 overlay(✨ 转圈 + 原文灰显 + "稍候"提示;CSS 动画由 index.html 自管)。 */
    private fun showOverlayCorrecting(text: String) {
        val t = JSONObject.quote(text)
        mainHandler.post { webView.evaluateJavascript("window.showOverlayCorrecting($t)", null) }
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
        /** 喂给纠错 prompt 的"最近语音指令"条数上限。 */
        private const val RECENT_MAX = 5
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
