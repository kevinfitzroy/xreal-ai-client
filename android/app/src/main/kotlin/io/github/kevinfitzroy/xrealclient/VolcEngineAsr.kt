package io.github.kevinfitzroy.xrealclient

import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONArray
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 火山引擎(豆包)大模型流式语音识别 —— 双向流式(优化版)WebSocket client,**真流式**:
 * 按下即连 WS,音频边录边推,中间结果实时回 [AsrCallback.onPartial],松手发负包拿最终结果。
 *
 * 接口:`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`(协议见 [VolcFrame] 与
 * refs/大模型流式语音识别API.md)。鉴权走 HTTP header(旧版控制台路径,无签名)。
 *
 * 失败语义:任何错误回 [AsrCallback.onError];服务端先关或超时但已有中间结果,则当 final 用
 * (优先把已说的字交出去)。不做 reconnect / retry。
 */
class VolcEngineAsr(
    private val appid: String,
    private val token: String,
    private val resourceId: String = "volc.seedasr.sauc.duration",
) : Asr {

    private val http = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)   // WS 长连,自管超时(finish 后看门狗)
        .build()

    override fun open(lang: String, hotwords: List<String>, callback: AsrCallback): AsrStream =
        VolcStream(callback, hotwords)

    private inner class VolcStream(private val cb: AsrCallback, private val hotwords: List<String>) : AsrStream {
        private val lock = Any()
        @Volatile private var cancelled = false
        private val done = AtomicBoolean(false)
        private var connected = false
        private var finishRequested = false
        private val pending = ArrayDeque<ByteArray>()   // onOpen 前缓冲的音频块(连接延迟竞态)
        @Volatile private var best = ""
        private val watchdog = Handler(Looper.getMainLooper())
        private val ws: WebSocket

        init {
            val req = Request.Builder()
                .url(ENDPOINT)
                .addHeader("X-Api-App-Key", appid)
                .addHeader("X-Api-Access-Key", token)
                .addHeader("X-Api-Resource-Id", resourceId)
                .addHeader("X-Api-Connect-Id", UUID.randomUUID().toString())
                .addHeader("X-Api-Request-Id", UUID.randomUUID().toString())
                .build()
            ws = http.newWebSocket(req, Listener())
        }

        private inner class Listener : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) {
                Log.d(TAG, "WS open logid=${response.header("X-Tt-Logid")}")
                synchronized(lock) {
                    if (cancelled) { ws.close(1000, null); return }
                    ws.send(VolcFrame.buildFullClientRequest(requestJson(hotwords).toByteArray()).toByteString())
                    while (pending.isNotEmpty()) {
                        ws.send(VolcFrame.buildAudio(pending.removeFirst(), last = false).toByteString())
                    }
                    connected = true
                    if (finishRequested) ws.send(VolcFrame.buildAudio(ByteArray(0), last = true).toByteString())
                }
            }

            override fun onMessage(ws: WebSocket, bytes: ByteString) {
                if (cancelled) return
                when (val f = VolcFrame.parse(bytes.toByteArray())) {
                    is VolcFrame.Parsed.Server -> {
                        val t = extractText(f.payloadJson)
                        if (t.isNotBlank()) { best = t; cb.onPartial(t) }
                        if (f.isLast) resolveFinal()
                    }
                    is VolcFrame.Parsed.Err -> {
                        Log.w(TAG, "server error code=${f.code} msg=${f.message}")
                        resolveError("code=${f.code}")
                    }
                    is VolcFrame.Parsed.Unknown -> Log.w(TAG, "unknown msg type=${f.type}")
                }
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                if (cancelled) return
                Log.w(TAG, "WS failure: ${t.message} httpCode=${response?.code} logid=${response?.header("X-Tt-Logid")}")
                resolveError(t.message ?: "ws failure")
            }

            override fun onClosing(ws: WebSocket, code: Int, reason: String) {
                if (!cancelled) resolveFinal()   // 服务端先关而没发 last 包:已有中间结果当 final
            }
        }

        override fun send(pcmChunk: ByteArray) {
            if (cancelled) return
            synchronized(lock) {
                if (connected) ws.send(VolcFrame.buildAudio(pcmChunk, last = false).toByteString())
                else pending.addLast(pcmChunk)
            }
        }

        override fun finish() {
            synchronized(lock) {
                if (cancelled) return
                finishRequested = true
                if (connected) ws.send(VolcFrame.buildAudio(ByteArray(0), last = true).toByteString())
                // 未连上:onOpen 排空 pending 后会补发负包
            }
            // 松手后才启看门狗:录音期间不超时(可长按)
            watchdog.postDelayed({ if (!cancelled) resolveFinal() }, FINAL_TIMEOUT_MS)
        }

        override fun cancel() {
            cancelled = true
            watchdog.removeCallbacksAndMessages(null)
            runCatching { ws.close(1000, "cancelled") }
        }

        /** 收尾:把 best 当最终结果交出去(可能为空 → VoiceDaemon 回 IDLE)。只生效一次。 */
        private fun resolveFinal() {
            if (done.compareAndSet(false, true)) {
                watchdog.removeCallbacksAndMessages(null)
                cb.onFinal(best.trim())
                runCatching { ws.close(1000, null) }
            }
        }

        private fun resolveError(reason: String) {
            if (done.compareAndSet(false, true)) {
                watchdog.removeCallbacksAndMessages(null)
                cb.onError(reason)
                runCatching { ws.close(1000, null) }
            }
        }
    }

    /** 命令场景:关 itn(防"一七"→"17")、关标点、关顺滑;result_type=full(partial 全量,直接替换)。 */
    private fun requestJson(hotwords: List<String>): String = JSONObject().apply {
        put("user", JSONObject().put("uid", "xreal-client"))
        put("audio", JSONObject().apply {
            put("format", "pcm"); put("codec", "raw")
            put("rate", 16000); put("bits", 16); put("channel", 1)
        })
        put("request", JSONObject().apply {
            put("model_name", "bigmodel")
            put("enable_itn", false)
            put("enable_punc", false)
            put("enable_ddc", false)
            put("result_type", "full")
            // 热词:corpus.context 是「字符串里嵌 JSON」(豆包文档的怪点),空则整个 corpus 不发。
            val words = Hotwords.cap(hotwords)
            if (words.isNotEmpty()) {
                Log.d(TAG, "hotwords sent: ${words.size}/${hotwords.size} (cap=200chars)")  // 只打数量,不打内容
                val ctx = JSONObject().put(
                    "hotwords",
                    JSONArray(words.map { JSONObject().put("word", it) }),
                ).toString()
                put("corpus", JSONObject().put("context", ctx))
            }
        })
    }.toString()

    private fun extractText(json: String): String = try {
        JSONObject(json).optJSONObject("result")?.optString("text").orEmpty()
    } catch (e: Exception) {
        Log.w(TAG, "parse result failed: ${e.message} raw=$json")
        ""
    }

    companion object {
        private const val TAG = "VolcEngineAsr"
        private const val ENDPOINT = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        private const val FINAL_TIMEOUT_MS = 8_000L
    }
}
