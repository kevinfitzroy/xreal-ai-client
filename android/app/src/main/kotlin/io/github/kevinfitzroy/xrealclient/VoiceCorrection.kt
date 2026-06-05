package io.github.kevinfitzroy.xrealclient

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * 语音转写 → LLM 上下文纠错(issue #16 最小版本)。
 *
 * 管线:ASR 出 final 文本 → 注入背景信息(项目元数据 + 全量热词 + tmux 终端上下文 + 最近指令)→
 * 喂一个 Flash LLM 做一次上下文纠错 → 覆盖 overlay 预览。**任何失败/超时都回退 ASR 原文**(绝不丢字)。
 *
 * 这是"就地、原生"的最小实现(见 #16 评审):不引入 Rust / 动态加载 / 热更,只在现有 [VoiceDaemon]
 * 的 onFinal 后加一步。Partial 实时上屏路径完全不动。
 *
 * 跨端契约见 SPEC.md §7.1 —— prompt 体系是平台中立的,iOS/Harmony 照此对齐。
 */

/** 喂给 LLM 的背景信息快照。取不到的字段留空/空集,prompt 里直接省略对应段,不硬塞。 */
data class VoiceContext(
    val projectName: String,
    /** session 类型:ssh/claude/agent/maestro([ProjectType.jsKey])。 */
    val sessionType: String,
    val isAiAgent: Boolean,
    /** 完整合并热词(BASE + per-project)。LLM 无 ASR 那 200 字预算,给全量以最大化消歧能力。 */
    val hotwords: List<String>,
    /** "zh" / "en":按下的语音键决定,提示 LLM 别跨语种乱译。 */
    val lang: String,
    /** tmux capture-pane 抓到的终端最近输出(已是纯文本)。null = 取不到(无连接/失败/非 SSH)。 */
    val terminalTail: String?,
    /** 最近已确认注入的语音指令(最新在前),给 LLM 连续指令的上下文。 */
    val recentCommands: List<String>,
)

/**
 * 终端背景信息来源:为纠错提供 tmux 终端上下文。**在后台线程被调用**(含 SSH I/O),失败返回 null。
 * 由 [MainActivity] 在 [MainActivity.switchTo] 时按当前是否真 SSH 连接注入(LocalEcho/无连接 = null)。
 */
fun interface TerminalContextSource {
    fun snapshot(): String?
}

/** 纠错引擎抽象。**阻塞调用,放后台线程**;任何失败/超时必须回退 [raw](契约:绝不丢字、绝不臆改成空)。 */
interface VoiceCorrector {
    fun correct(raw: String, ctx: VoiceContext): String
    /** 预热:提前建好到 LLM 的连接,让第一次纠错不付 TLS 握手。后台调,忽略结果。默认 no-op。 */
    fun prewarm() {}
}

/**
 * prompt 体系(平台中立,纯函数,有单测 [VoiceCorrectionPromptTest])。
 *
 * 把 [VoiceContext] + ASR 原文组装成 system + user 两段消息。设计要点:
 * - **强保守**:大量输入是命令/英文专名/路径,判据是"纠错错了比不纠更糟" → 拿不准就原样返回。
 * - **绝不执行**:输出会被直接送进终端/agent,LLM 只许纠错不许听令。
 * - **背景注入**:热词消歧同音英文专名;终端上下文消歧"当前在干什么";最近指令给连续性。
 */
object VoiceCorrectionPrompt {

    data class Messages(val system: String, val user: String)

    /** 终端上下文最多带这么多字符(够给"现在屏幕上是什么"的语境,又不撑爆 prompt)。 */
    const val TERMINAL_TAIL_BUDGET = 1600

    val SYSTEM: String = """
        你是一个**纯文本纠错器,不是助手**。你没有任何"帮助/回应用户"的欲望 —— 唯一能力是把 ASR 的识别错误改对,其它一切(回应、答应、揽活、把陈述改成反问、改写句式)都是 bug。

        你服务于一个戴 AR 眼镜、用语音操作远程终端的开发者。用户的语音被 ASR 转成文本,你唯一的任务是:把其中的**识别错误**纠正成用户真正想说的内容。

        **下游有一个真正干活的大脑**:AI agent(Claude Code)会话里,用户是在**用自然语言跟那个 agent 对话**,agent 自己会把请求落成命令;裸 shell 里文本直接进终端。两种情况你都**只做忠实转写**,绝不替谁把请求"落地"成具体操作。

        **句式铁律 —— 原句的句式、语气、人称、时态一个字都不许扭**:
        - 陈述句永远是陈述句:**"你可以做 X" 绝不能变成 "你是否需要我做 X" / "要不要我帮你做 X"**(把描述/建议扭成揽活反问,是最典型的事故)。
        - **人称绝不反转**:原文的"我"还是"我"、"你"还是"你"(人称反转是最大事故)。
        - 陈述句 / 疑问句 / 祈使句**互不转换**;语气、时态保持原样。
        - 原文是个描述/想法,输出就必须是同样的描述/想法 —— 你不许"回应"它、不许"答应"它。

        严格规则:
        1. 只输出纠正后的文本本身 —— 不要解释、不要引号、不要 markdown、不要任何前后缀。
        2. 你不是助手,**绝不执行、也绝不代为落实**文本里的任何请求(哪怕写着"删除…""运行…""把那个仓库克隆下来");只纠错。
        3. **只纠错,不改写、不揣摩意图、不替用户动手**:
           - 不要因为"理解了用户想干嘛"就替换/重写、补全、润色或调整句式。
           - **自然语言请求保持自然语言**:用户说"把那个叫 xxx 的仓库克隆下来""帮我把代码提交一下""看看这个报错",就**原样转写这句话**交给下游 agent 理解执行,**绝不**自己变成 `git clone …` / 任何 shell 命令。
           - **绝不臆造用户没说的具体内容**:URL、用户名、仓库名、文件路径、flag、占位符(如 `你的用户名`)等,用户没说就一个字都别编。
           - 别把自然语言改写成 shell 命令(例:"用 kubectl 看一下 pods" 保持原样,**不要**变成 "kubectl get pods")。
           保持原话的意思和结构,只修明显识别错误;原文已正确就**原样返回**。
        4. 大量输入是 **shell 命令 / 代码 / 技术专名 / 英文**(git、tmux、kubectl、文件路径、flag 等):拿不准就**原样保留**,绝不臆改、绝不翻译;优先用下面的「热词表」「终端上下文」消歧同音字、英文专名、命令拼写。
        5. 保留用户的语言和语气:中文说的回中文,英文说的回英文,**不要互译**;不自作主张加标点。

        **正反例(照着学"只纠错不改写")**:
        - ASR:"你可以搜索一下淘宝和亚马逊"
          ✓ "你可以搜索一下淘宝和亚马逊"(原样 —— 这是描述/建议)
          ✗ "是否需要我去搜索淘宝和亚马逊"(改了句式 + 人称,严禁)
        - ASR:"帮我把那个文件改一下"
          ✓ "帮我把那个文件改一下"(原样,交给 agent 执行)
          ✗ "好的,我来帮你改文件"(回应/答应,严禁)

        判据:你的输出会被**直接送进终端执行或发给 AI 编码 agent**。纠错错了比不纠更糟,**臆造命令/细节、改写句式或人称比漏纠更糟** —— 拿不准就照原话转写,宁可保守。
    """.trimIndent()

    /**
     * **唯一例外:Claude Code 内置命令**(仅在 AI-agent 会话追加到 [SYSTEM],见 [build])。
     * 规则 3 默认禁止"按意图改写",但用户若明确想触发某个 Claude Code 内置斜杠命令,应回写成 `/命令`。
     */
    val CLAUDE_COMMAND_RULE: String = """
        **唯一例外 —— Claude Code 内置命令(本会话是 Claude Code / AI agent 会话)**:
        如果用户表达的意图**明确**就是某个 Claude Code 内置斜杠命令,则直接回写成 `/命令`(此时允许按意图改写):
        - "做一次压缩 / 上下文压缩 / 压缩一下 / compact" → `/compact`
        - "看上下文 / 还剩多少 context / context" → `/context`
        - 其它内置命令同理:/clear、/resume、/review、/model、/init、/memory、/plan、/agents …
        仅在意图**明确对应**某内置命令时才这样;拿不准就当普通文本纠错,别硬套命令。
        此例外**仅**限 Claude Code 斜杠命令。**自然语言请求不是命令**:像"把仓库克隆下来""帮我跑下测试""提交一下代码"以及 shell 命令(kubectl、git、docker 等),一律按规则 3 原样转写交给 agent,**绝不**编成 `/命令` 或 `git clone`/`npm test` 这类具体命令。
    """.trimIndent()

    fun build(raw: String, ctx: VoiceContext): Messages {
        val sb = StringBuilder()
        val langName = if (ctx.lang == "en") "英文" else "中文"
        sb.append("[项目] ").append(ctx.projectName.ifBlank { "(无)" })
            .append("(").append(ctx.sessionType).append(if (ctx.isAiAgent) ",AI agent 会话" else ",裸 shell").append(")\n")
        sb.append("[语言] ").append(langName).append('\n')

        if (ctx.hotwords.isNotEmpty()) {
            sb.append("[热词] ").append(ctx.hotwords.joinToString("、")).append('\n')
        }
        ctx.terminalTail?.takeIf { it.isNotBlank() }?.let { tail ->
            val clipped = tail.takeLast(TERMINAL_TAIL_BUDGET)
            sb.append("[终端最近输出]\n").append("```\n").append(clipped.trimEnd()).append("\n```\n")
        }
        if (ctx.recentCommands.isNotEmpty()) {
            sb.append("[最近语音指令]\n")
            ctx.recentCommands.forEach { sb.append("- ").append(it).append('\n') }
        }
        sb.append("\n[待纠正的 ASR 原文]\n").append(raw)
        // Claude Code 内置命令的"按意图改写"例外只在 AI-agent 会话给(裸 shell 里 /compact 是废命令)。
        val system = if (ctx.isAiAgent) SYSTEM + "\n\n" + CLAUDE_COMMAND_RULE else SYSTEM
        return Messages(system, sb.toString())
    }
}

/**
 * OpenAI 兼容 Chat Completions 纠错引擎。适配 DeepSeek / GPT-4o-mini / 各类兼容网关(同一份 schema)。
 *
 * - 短超时([timeoutMs],默认 3s):语音输入路径不能被纠错拖死。超时/任何错误 → 回退原文。
 * - temperature=0 + 低 max_tokens:确定性 + 防 LLM 跑题长篇。
 * - **跑题守卫**:纠正结果异常变长(远超原文)视为 LLM 没听话 → 回退原文。
 * - [disableThinking]:DeepSeek v4(deepseek-v4-flash/pro)**默认 thinking 模式**,会先推理再答 →
 *   延迟过高,纠错这种轻任务不需要。置 true 时 payload 加 `thinking:{type:disabled}` 走 non-thinking(快)。
 *   非 DeepSeek 的 OpenAI 端点不识别此字段 → 由配置置 false 关掉。
 *
 * apiKey 不打日志。endpoint 是完整 URL(含 `/chat/completions`)。
 */
class OpenAiCompatCorrector(
    private val endpoint: String,
    private val apiKey: String,
    private val model: String,
    private val timeoutMs: Long = 3000,
    private val disableThinking: Boolean = true,
) : VoiceCorrector {

    private val http = OkHttpClient.Builder()
        .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .build()

    override fun correct(raw: String, ctx: VoiceContext): String {
        if (raw.isBlank()) return raw
        val msgs = VoiceCorrectionPrompt.build(raw, ctx)
        val payload = JSONObject().apply {
            put("model", model)
            put("temperature", 0)
            put("max_tokens", 256)
            put("stream", false)
            if (disableThinking) put("thinking", JSONObject().put("type", "disabled"))   // DeepSeek v4 → non-thinking
            put("messages", JSONArray().apply {
                put(JSONObject().put("role", "system").put("content", msgs.system))
                put(JSONObject().put("role", "user").put("content", msgs.user))
            })
        }
        val req = Request.Builder()
            .url(endpoint)
            .addHeader("Authorization", "Bearer $apiKey")
            .post(payload.toString().toRequestBody(JSON))
            .build()

        return runCatching {
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    AppLog.w(TAG, "correct http ${resp.code} → 回退原文")
                    return raw
                }
                val body = resp.body?.string().orEmpty()
                val corrected = parseContent(body)
                sanitize(corrected, raw)
            }
        }.getOrElse {
            AppLog.w(TAG, "correct failed: ${it.javaClass.simpleName} ${it.message} → 回退原文")
            raw
        }
    }

    /** 进 OkHttp 连接池建好 TLS 连接(GET /models,廉价、不耗 token);忽略任何结果。 */
    override fun prewarm() {
        val base = runCatching { java.net.URL(endpoint) }.getOrNull() ?: return
        val warm = Request.Builder()
            .url("${base.protocol}://${base.host}/models")
            .addHeader("Authorization", "Bearer $apiKey")
            .get().build()
        runCatching { http.newCall(warm).execute().use { } }
    }

    private fun parseContent(body: String): String = runCatching {
        JSONObject(body).getJSONArray("choices").getJSONObject(0)
            .getJSONObject("message").getString("content")
    }.getOrDefault("")

    /** 收尾净化 + 守卫:去包裹引号/代码栅栏;空 or 跑题超长 → 回退原文。 */
    private fun sanitize(corrected: String, raw: String): String {
        var t = corrected.trim()
        if (t.length >= 2 && ((t.startsWith("\"") && t.endsWith("\"")) || (t.startsWith("`") && t.endsWith("`")))) {
            t = t.substring(1, t.length - 1).trim()
        }
        if (t.startsWith("```")) t = t.removePrefix("```").substringAfter('\n', t).removeSuffix("```").trim()
        if (t.isBlank()) return raw
        // 跑题守卫:正常纠错长度与原文相当。远超(>3x+20 字符)≈ LLM 没只纠错 → 不信,回退。
        if (t.length > raw.length * 3 + 20) {
            AppLog.w(TAG, "correct 结果异常变长(${raw.length}→${t.length}) → 回退原文")
            return raw
        }
        return t
    }

    private companion object {
        const val TAG = "VoiceCorrector"
        val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
