package io.github.kevinfitzroy.xrealclient

import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/**
 * 火山引擎(豆包)大模型流式语音识别 —— 双向流式(优化版)WebSocket client。
 *
 * 接口:`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`(协议见 [VolcFrame] 与
 * refs/大模型流式语音识别API.md)。鉴权走 HTTP header(旧版控制台路径,无签名)。
 *
 * **录音回放模式**:VoiceDaemon 是"按住说话"——松手才拿到完整 WAV。这里把已录好的 PCM 按
 * 200ms 分包、间隔 ~50ms 喂进流式接口(吃到流式低延迟,又不触发"发包过小")。真·边录边传是
 * Phase 2+ 的事,届时 [Asr] seam 再演进(需要真麦,emulator 测不了)。
 *
 * 失败语义:任何错误(连不上 / 错误帧 / 超时 / 空音频)都返回 ""。VoiceDaemon 收到空串即回 IDLE,
 * 用户重按 F13/F14 重试 —— 不做 reconnect / retry。
 *
 * @param appid    X-Api-App-Key(火山控制台 APP ID)
 * @param token    X-Api-Access-Key(火山控制台 Access Token)
 * @param resourceId X-Api-Resource-Id,默认豆包流式 2.0 小时版
 */
class VolcEngineAsr(
    private val appid: String,
    private val token: String,
    private val resourceId: String = "volc.seedasr.sauc.duration",
) : Asr {

    private val http = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)   // WS 长连,自管超时(withTimeoutOrNull)
        .build()

    override suspend fun recognize(audio: ByteArray, lang: String): String {
        if (audio.size <= WAV_HEADER) return ""           // 空音频:不开 WS
        val pcm = audio.copyOfRange(WAV_HEADER, audio.size)

        val result = withTimeoutOrNull(TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                val resolved = AtomicBoolean(false)
                fun finish(ws: WebSocket?, text: String) {
                    if (resolved.compareAndSet(false, true)) {
                        ws?.close(1000, null)
                        cont.resume(text)
                    }
                }

                var best = ""   // 仅 listener(reader)线程访问
                var sender: Thread? = null

                val listener = object : WebSocketListener() {
                    override fun onOpen(ws: WebSocket, response: Response) {
                        Log.d(TAG, "WS open logid=${response.header("X-Tt-Logid")}")
                        sender = Thread({ runCatching { streamPcm(ws, pcm) } }, "volc-asr-send").also { it.start() }
                    }

                    override fun onMessage(ws: WebSocket, bytes: ByteString) {
                        when (val f = VolcFrame.parse(bytes.toByteArray())) {
                            is VolcFrame.Parsed.Server -> {
                                extractText(f.payloadJson).takeIf { it.isNotBlank() }?.let { best = it }
                                if (f.isLast) finish(ws, best.trim())
                            }
                            is VolcFrame.Parsed.Err -> {
                                Log.w(TAG, "server error code=${f.code} msg=${f.message}")
                                finish(ws, "")
                            }
                            is VolcFrame.Parsed.Unknown -> Log.w(TAG, "unknown msg type=${f.type}")
                        }
                    }

                    override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                        // httpCode 区分握手失败(401/403=凭证/resourceId 错)vs 协议层失败。
                        Log.w(TAG, "WS failure: ${t.message} httpCode=${response?.code} logid=${response?.header("X-Tt-Logid")}")
                        finish(null, "")
                    }

                    override fun onClosing(ws: WebSocket, code: Int, reason: String) {
                        finish(null, best.trim())   // 兜底:服务端先关而没发 last 包
                    }
                }

                val req = Request.Builder()
                    .url(ENDPOINT)
                    .addHeader("X-Api-App-Key", appid)
                    .addHeader("X-Api-Access-Key", token)
                    .addHeader("X-Api-Resource-Id", resourceId)
                    .addHeader("X-Api-Connect-Id", UUID.randomUUID().toString())
                    .addHeader("X-Api-Request-Id", UUID.randomUUID().toString())
                    .build()
                val ws = http.newWebSocket(req, listener)

                cont.invokeOnCancellation {
                    sender?.interrupt()
                    ws.close(1000, "cancelled")   // ESC / 连按 F13:真关 WS,别让旧回调污染下一次
                }
            }
        }
        return result ?: ""
    }

    /** 发 full client request,再把 PCM 按 200ms 分包喂入(间隔 50ms)。最后一包打 last 标记。 */
    private fun streamPcm(ws: WebSocket, pcm: ByteArray) {
        ws.send(VolcFrame.buildFullClientRequest(buildRequestJson().toByteArray()).toByteString())
        var off = 0
        while (off < pcm.size) {
            val end = (off + CHUNK).coerceAtMost(pcm.size)
            val last = end >= pcm.size
            ws.send(VolcFrame.buildAudio(pcm.copyOfRange(off, end), last).toByteString())
            off = end
            if (!last) Thread.sleep(SEND_INTERVAL_MS)
        }
    }

    /** 命令场景:关 itn(防"一七"→"17")、关标点(防句号污染命令)、关顺滑。bigmodel_async 不收 language。 */
    private fun buildRequestJson(): String = JSONObject().apply {
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
        private const val WAV_HEADER = 44
        private const val CHUNK = 6400              // 200ms @ 16kHz·16bit·mono
        private const val SEND_INTERVAL_MS = 50L
        private const val TIMEOUT_MS = 10_000L
    }
}
