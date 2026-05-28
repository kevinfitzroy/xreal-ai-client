package io.github.kevinfitzroy.xrealclient

import android.util.Base64
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * 火山引擎(豆包)短语音识别 REST 客户端。
 *
 * **API 端点细节会随 Volcengine 文档变更**;这个实现按 2024-2025 期间公开的
 * "极速版"/"录音文件识别" REST 接口写。User 拿到 console 给的具体端点 + appid + token
 * 后,可能需要微调 [endpoint]、[buildRequest] 或 [parseResponse]。
 *
 * 文档参考:https://www.volcengine.com/docs/6561/80816
 *
 * 用法:
 *   val asr = VolcEngineAsr(appid="...", token="...", cluster="volcengine_input_common")
 *   val text = asr.recognize("zh")  // 内部需要喂 WAV bytes —— 重载见 [recognizeAudio]
 */
class VolcEngineAsr(
    private val appid: String,
    private val token: String,
    private val cluster: String = "volcengine_input_common",
    private val endpoint: String = "https://openspeech.bytedance.com/api/v1/asr",
) : Asr {

    private val http = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    /**
     * 真实 ASR 请求。Body 结构按 Volcengine REST API(可能与你 console 看到的略不同 —
     * 需要核对响应字段名 `result.text` vs `payload_msg.results[0].text` 等)。
     */
    override suspend fun recognize(audio: ByteArray, lang: String): String = withContext(Dispatchers.IO) {
        if (audio.isEmpty()) return@withContext ""
        val wav = audio
        val reqJson = JSONObject().apply {
            put("app", JSONObject().apply {
                put("appid", appid)
                put("cluster", cluster)
                put("token", token)
            })
            put("user", JSONObject().apply {
                put("uid", "xreal-client")
            })
            put("audio", JSONObject().apply {
                put("format", "wav")
                put("rate", 16000)
                put("bits", 16)
                put("channel", 1)
                put("language", if (lang == "en") "en-US" else "zh-CN")
                put("data", Base64.encodeToString(wav, Base64.NO_WRAP))
            })
            put("request", JSONObject().apply {
                put("reqid", UUID.randomUUID().toString())
                put("nbest", 1)
                put("show_utterances", false)
                put("result_type", "full")
            })
        }
        val body = reqJson.toString().toRequestBody("application/json".toMediaType())
        val req = Request.Builder()
            .url(endpoint)
            .addHeader("Authorization", "Bearer; $token")
            .post(body)
            .build()
        try {
            http.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    Log.w(TAG, "HTTP ${resp.code}: $text")
                    return@withContext ""
                }
                parseResponse(text)
            }
        } catch (e: Exception) {
            Log.w(TAG, "request failed: ${e.message}")
            ""
        }
    }

    private fun parseResponse(json: String): String {
        // Volcengine 响应结构可能是:
        //   { "code": 1000, "result": [{ "text": "..." }] }  (一种)
        //   { "payload_msg": { "result": [{ "text": "..." }] } }  (另一种,流式版本)
        // 这里两种都试,取第一个非空 text。
        val text = try {
            val obj = JSONObject(json)
            obj.optJSONArray("result")?.optJSONObject(0)?.optString("text")?.takeIf { it.isNotBlank() }
                ?: obj.optJSONObject("payload_msg")
                    ?.optJSONArray("result")?.optJSONObject(0)?.optString("text").orEmpty()
        } catch (e: Exception) {
            Log.w(TAG, "parse response failed: ${e.message}\nraw=$json")
            return ""
        }
        if (text.isBlank()) {
            // 第一次接 user 的 Volc account 时这里多半会触发 ——
            // 给 user 看 raw response 让他能对照 Volcengine console 文档调 endpoint/fields
            Log.w(TAG, "empty parse — raw response: $json")
        }
        return text
    }

    companion object { private const val TAG = "VolcEngineAsr" }
}
