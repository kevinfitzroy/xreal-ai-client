package io.github.kevinfitzroy.xrealclient

import android.content.Context
import android.content.SharedPreferences

/**
 * SSH + ASR 配置持久化(SharedPreferences)。
 * 私钥 PEM 也存这里 —— Phase 0/B 简化,Phase 2+ 改 EncryptedSharedPreferences。
 */
data class SshConfig(
    val host: String,
    val port: Int = 22,
    val user: String,
    val privateKeyPem: String,
    val startupCommand: String = "abduco -A dev bash",
) {
    fun isComplete(): Boolean =
        host.isNotBlank() && user.isNotBlank() && privateKeyPem.isNotBlank()
}

enum class AsrProvider { NONE, MOCK, VOLC }

data class AsrConfig(
    val provider: AsrProvider = AsrProvider.MOCK,
    val appid: String = "",          // X-Api-App-Key
    val token: String = "",          // X-Api-Access-Key
    val resourceId: String = DEFAULT_RESOURCE_ID,   // X-Api-Resource-Id
) {
    fun isVolcConfigured(): Boolean =
        provider == AsrProvider.VOLC && appid.isNotBlank() && token.isNotBlank()

    companion object {
        /** 豆包流式语音识别模型 2.0 小时版。 */
        const val DEFAULT_RESOURCE_ID = "volc.seedasr.sauc.duration"
    }
}

/**
 * 语音转写 LLM 上下文纠错配置(issue #16)。OpenAI 兼容 Chat Completions(DeepSeek/GPT-4o-mini/兼容网关)。
 * 经代客安装(§8 同 ASR 通道)进私有 [SettingsStore.PRIVATE_CORRECTION],**无设置 UI**。未配置 → 纠错关闭(= 现状行为)。
 */
data class CorrectionConfig(
    val enabled: Boolean = false,
    val endpoint: String = "",       // 完整 URL,含 /chat/completions
    val apiKey: String = "",
    val model: String = "",
    val timeoutMs: Long = 5000,
    /** DeepSeek v4 默认 thinking 模式 → 纠错走 non-thinking(快)。非 DeepSeek 端点置 false。 */
    val disableThinking: Boolean = true,
) {
    fun isConfigured(): Boolean =
        enabled && endpoint.isNotBlank() && apiKey.isNotBlank() && model.isNotBlank()
}

class SettingsStore(ctx: Context) {

    private val prefs: SharedPreferences =
        ctx.getSharedPreferences("xreal_settings", Context.MODE_PRIVATE)
    private val filesDir: java.io.File = ctx.filesDir   // app 私有目录 /data/data/<pkg>/files

    fun loadSsh(): SshConfig = SshConfig(
        host = prefs.getString(K_SSH_HOST, "") ?: "",
        port = prefs.getInt(K_SSH_PORT, 22),
        user = prefs.getString(K_SSH_USER, "") ?: "",
        privateKeyPem = prefs.getString(K_SSH_KEY_PEM, "") ?: "",
        startupCommand = prefs.getString(K_SSH_STARTUP, "abduco -A dev bash")
            ?: "abduco -A dev bash",
    )

    fun saveSsh(c: SshConfig) {
        prefs.edit()
            .putString(K_SSH_HOST, c.host)
            .putInt(K_SSH_PORT, c.port)
            .putString(K_SSH_USER, c.user)
            .putString(K_SSH_KEY_PEM, c.privateKeyPem)
            .putString(K_SSH_STARTUP, c.startupCommand)
            .apply()
    }

    /**
     * ASR 配置来源优先级:
     *   1. Valet 经 adb 推、导入到私有存储的 [PRIVATE_ASR](无 UI 通道,与 hosts/keys 同构)。
     *   2. SharedPreferences(ConfigActivity 的 dev fallback)。
     *   3. 都没有 → 默认 MOCK。
     * 假设 [loadHosts]/[importStagingIfPresent] 已先跑过(MainActivity 顺序保证),staging 里的 asr.json 已落私有。
     */
    fun loadAsr(): AsrConfig {
        val privateAsr = java.io.File(filesDir, PRIVATE_ASR)
        if (privateAsr.exists()) {
            runCatching {
                val o = org.json.JSONObject(privateAsr.readText())
                return AsrConfig(
                    provider = runCatching { AsrProvider.valueOf(o.optString("provider", "VOLC").uppercase()) }
                        .getOrDefault(AsrProvider.VOLC),
                    appid = o.optString("appid"),
                    token = o.optString("token"),
                    resourceId = o.optString("resourceId", AsrConfig.DEFAULT_RESOURCE_ID),
                )
            }.onFailure { android.util.Log.w("SettingsStore", "私有 asr.json 解析失败,回退 prefs: ${it.message}") }
        }
        return AsrConfig(
            provider = runCatching {
                AsrProvider.valueOf(prefs.getString(K_ASR_PROVIDER, AsrProvider.MOCK.name)!!)
            }.getOrDefault(AsrProvider.MOCK),
            appid = prefs.getString(K_ASR_APPID, "") ?: "",
            token = prefs.getString(K_ASR_TOKEN, "") ?: "",
            resourceId = prefs.getString(K_ASR_RESOURCE_ID, AsrConfig.DEFAULT_RESOURCE_ID)
                ?: AsrConfig.DEFAULT_RESOURCE_ID,
        )
    }

    /**
     * LLM 纠错配置(issue #16)。来源:Valet 导入到私有 [PRIVATE_CORRECTION] 的 correction.json(无 UI 通道,与 asr.json 同构)。
     * 文件不存在/解析失败/缺字段 → 返回 disabled(纠错关闭,回退现状行为)。假设 [importStagingIfPresent] 已先跑(MainActivity 顺序保证)。
     */
    fun loadCorrection(): CorrectionConfig {
        val f = java.io.File(filesDir, PRIVATE_CORRECTION)
        if (!f.exists()) return CorrectionConfig()
        return runCatching {
            val o = org.json.JSONObject(f.readText())
            CorrectionConfig(
                enabled = o.optBoolean("enabled", true),   // 配了文件默认开,除非显式 false
                // endpoint/model 默认 DeepSeek v4 flash(项目默认引擎,见 #16)→ correction.json 最简只需 {apiKey}
                endpoint = o.optString("endpoint", "https://api.deepseek.com/chat/completions"),
                apiKey = o.optString("apiKey"),
                model = o.optString("model", "deepseek-v4-flash"),
                timeoutMs = o.optLong("timeoutMs", 5000L),
                disableThinking = o.optBoolean("disableThinking", true),   // v4 默认 thinking → 关掉走 non-thinking
            )
        }.getOrElse {
            android.util.Log.w("SettingsStore", "私有 correction.json 解析失败 → 纠错关闭: ${it.message}")
            CorrectionConfig()
        }
    }

    /**
     * Agent Deck 的 host/project 列表。来源优先级:
     *   1. 代客安装(Valet Setup)导入:staging 有内容则先导入到私有存储(见 [importStagingIfPresent])。
     *   2. 私有 [PRIVATE_HOSTS]:导入后的真相来源,存 app 私有目录,**reboot 不丢**。
     *   3. legacy [HOSTS_JSON](`/data/local/tmp`,dev rig 用):仅在没有私有配置时回退。reboot 清零。
     *
     * schema(私有/legacy 一致):
     * `[{ "name","addr","host","port","user","keyPath","projects":[{"session","name","type"}] }]`
     * keyPath 指向设备上的私钥文件(由 [readPemSafe] 校验后读成 PEM)。都没有 → 空列表(走 mock)。
     */
    fun loadHosts(): List<HostConfig> {
        runCatching { importStagingIfPresent() }
            .onFailure { android.util.Log.w("SettingsStore", "Valet 导入失败(保留 staging 供排查): ${it.message}") }

        val privateFile = java.io.File(filesDir, PRIVATE_HOSTS)
        val legacyFile = java.io.File(HOSTS_JSON)
        val src = when {
            privateFile.exists() -> {
                if (legacyFile.exists())
                    android.util.Log.w("SettingsStore", "私有 hosts.json 已存在 → 忽略 legacy $HOSTS_JSON(dev rig 的 adb push 不会生效;要走 dev rig 先删私有配置)")
                privateFile
            }
            legacyFile.exists() -> legacyFile
            else -> return emptyList()
        }
        return parseHosts(src)
    }

    private fun parseHosts(f: java.io.File): List<HostConfig> = try {
        val (arr, proxies) = splitTopLevel(f.readText())   // 顶层数组(legacy)或 {proxies,hosts}(SPEC §8)
        val hosts = (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            HostConfig(
                name = o.getString("name"),
                addr = o.optString("addr", o.getString("host")),
                ssh = SshConfig(
                    host = o.getString("host"),
                    port = o.optInt("port", 22),
                    user = o.getString("user"),
                    privateKeyPem = readPemSafe(o.getString("keyPath")),
                ),
                projects = o.getJSONArray("projects").let { pj ->
                    (0 until pj.length()).map { j ->
                        val p = pj.getJSONObject(j)
                        ProjectConfig(
                            sessionName = p.getString("session"),
                            displayName = p.optString("name", p.getString("session")),
                            type = ProjectType.valueOf(p.getString("type").uppercase()),
                            hotwords = p.optJSONArray("hotwords")
                                ?.let { hw -> (0 until hw.length()).map { hw.getString(it) } }
                                ?: emptyList(),
                        )
                    }
                },
                basePath = o.optString("basePath", ""),
                via = o.optString("via").ifBlank { null },   // 多跳跳板 host 名(无则直连)
                proxy = parseHostProxy(o, proxies),          // SSH-over-443(SPEC §5.1;无 proxy 字段=直连)
            )
        }
        // fail closed(SPEC §5.1):localPort 冲突 = 拒绝整份配置,**绝不退回直连**(直连的 :22 正是被 GFW 卡的)。
        localPortConflict(hosts)?.let {
            throw IllegalStateException("proxy localPort 冲突,拒绝整份 hosts 配置(不退回直连):$it")
        }
        hosts
    } catch (e: Exception) {
        android.util.Log.w("SettingsStore", "parseHosts 解析 ${f.path} 失败: ${e.message}")
        emptyList()
    }

    /**
     * host 的 SSH-over-443 proxy(SPEC §8/§5.1)。两形态:
     *   - **目标契约**:host 内联对象 `proxy{name,localPort,url}`。
     *   - **legacy 兼容**:host 字符串 `"proxy":"<名>"` 引用顶层 `proxies` 表([splitTopLevel] 已合成 localPort)。
     * **无 proxy 字段 = 直连**(返回 null);proxy **指定了却非法/未定义** = 抛(由 [parseHosts] fail closed,绝不静默直连)。
     */
    private fun parseHostProxy(o: org.json.JSONObject, proxies: Map<String, ProxyConfig>): ProxyConfig? {
        val hostName = o.optString("name")
        o.optJSONObject("proxy")?.let { po ->   // 内联对象
            val name = po.optString("name"); val url = po.optString("url"); val lp = po.optInt("localPort", 0)
            require(name.isNotBlank() && url.isNotBlank() && lp in 1..65535) {
                "host '$hostName' 内联 proxy 非法(需 name/url/localPort∈1..65535)"
            }
            return ProxyConfig(name, lp, url)
        }
        val ref = o.optString("proxy").ifBlank { return null }   // 无 proxy 字段 → 直连
        return proxies[ref] ?: throw IllegalStateException("host '$hostName' 引用未定义 proxy '$ref'")
    }

    /** hosts.json 顶层两形态(SPEC §8):顶层数组 = legacy(无 proxy);顶层对象 `{proxies,hosts}`。
     *  返回 (hosts 数组, proxy 名→ProxyConfig)。legacy 顶层 `proxies` 表无 localPort → 按序合成固定口
     *  ([LEGACY_PROXY_PORT_BASE]+序号),让 legacy 也走 host 内联同一套固定端口模型。 */
    private fun splitTopLevel(text: String): Pair<org.json.JSONArray, Map<String, ProxyConfig>> {
        val t = text.trim()
        if (t.startsWith("[")) return org.json.JSONArray(t) to emptyMap()
        val o = org.json.JSONObject(t)
        val hosts = o.optJSONArray("hosts") ?: org.json.JSONArray()
        val proxies = LinkedHashMap<String, ProxyConfig>()
        o.optJSONArray("proxies")?.let { pa ->
            for (i in 0 until pa.length()) {
                val p = pa.getJSONObject(i)
                val name = p.optString("name"); val url = p.optString("url")
                val lp = p.optInt("localPort", LEGACY_PROXY_PORT_BASE + i)   // legacy 无 localPort → 合成
                if (name.isNotBlank() && url.isNotBlank()) proxies[name] = ProxyConfig(name, lp, url)
                else android.util.Log.w("SettingsStore", "proxies[$i] 缺 name/url,跳过")
            }
        }
        return hosts to proxies
    }

    /**
     * 代客安装的"上传"落地:把 Valet 经 adb push 到 staging 的 host 配置 + 私钥,导入 app 私有存储。
     * staging 形状:`/data/local/tmp/xreal_import/{hosts.json, <keyfile>...}`,host 对象用 `key`(纯文件名)
     * 指向同目录的私钥。导入后 key 落到私有 `keys/<host>.pem`(600),`key`→`keyPath`,整批原子写 [PRIVATE_HOSTS]。
     * staging 清理是 **best-effort** —— app 是 untrusted_app SELinux 域,通常能读但无权删 `/data/local/tmp`,
     * 所以**权威清理交给 Valet**(`adb shell rm`,见 docs/agent-setup-guide.md)。无 staging → 直接返回。
     */
    private fun importStagingIfPresent() {
        val staging = java.io.File(STAGING_DIR)
        val stagedHosts = java.io.File(staging, "hosts.json")
        val stagedAsr = java.io.File(staging, "asr.json")
        val stagedCorrection = java.io.File(staging, "correction.json")
        if (!stagedHosts.exists() && !stagedAsr.exists() && !stagedCorrection.exists()) return

        // 清理上次崩溃残留的半成品(原子写的 .tmp)
        val keysDir = java.io.File(filesDir, "keys").apply { mkdirs() }
        filesDir.listFiles { _, n -> n.endsWith(".tmp") }?.forEach { it.delete() }
        keysDir.listFiles { _, n -> n.endsWith(".tmp") }?.forEach { it.delete() }

        var hostCount = 0
        if (stagedHosts.exists()) {
            // 顶层两形态(SPEC §8):数组 = legacy;对象 {proxies,hosts} = 新。改写的是 hosts 数组里每项的
            // key→keyPath;proxies(仅含 vmess url,无文件引用)原样保留,整个 root 写回。
            val text = stagedHosts.readText().trim()
            val root: Any = if (text.startsWith("[")) org.json.JSONArray(text) else org.json.JSONObject(text)
            val arr: org.json.JSONArray =
                if (root is org.json.JSONArray) root else (root as org.json.JSONObject).optJSONArray("hosts") ?: org.json.JSONArray()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val safeName = o.getString("name").replace(Regex("[^A-Za-z0-9_.-]"), "_")
                val keyName = o.getString("key")
                require(
                    keyName.isNotBlank() && !keyName.contains('/') && !keyName.contains("..") &&
                        !java.io.File(keyName).isAbsolute,
                ) { "key 必须是 staging 内的纯文件名(防路径遍历): $keyName" }
                val stagedKey = java.io.File(staging, keyName)
                require(stagedKey.exists() && stagedKey.length() in 1..8192) { "staging 私钥不存在或过大: $keyName" }
                val pem = stagedKey.readText()
                require(pem.contains("PRIVATE KEY")) { "不是合法私钥: $keyName" }

                val destKey = java.io.File(keysDir, "$safeName.pem")
                writeAtomic(destKey, pem)
                destKey.setReadable(false, false); destKey.setReadable(true, true)   // 600:仅 app uid 可读
                destKey.setWritable(false, false); destKey.setWritable(true, true)

                o.put("keyPath", destKey.absolutePath)
                o.remove("key")
            }
            writeAtomic(java.io.File(filesDir, PRIVATE_HOSTS), root.toString())
            hostCount = arr.length()
        }

        // ASR 凭证:校验 JSON 合法后原子落私有存储(无 UI 通道,与 hosts/keys 同构)。
        var asrImported = false
        if (stagedAsr.exists()) {
            val raw = stagedAsr.readText()
            require(stagedAsr.length() in 1..4096) { "asr.json 过大" }
            org.json.JSONObject(raw)   // 解析失败即抛,不落坏文件
            writeAtomic(java.io.File(filesDir, PRIVATE_ASR), raw)
            asrImported = true
        }

        // 纠错配置:校验 JSON 合法后原子落私有存储(无 UI 通道,与 asr.json 同构)。
        var correctionImported = false
        if (stagedCorrection.exists()) {
            val raw = stagedCorrection.readText()
            require(stagedCorrection.length() in 1..4096) { "correction.json 过大" }
            org.json.JSONObject(raw)   // 解析失败即抛,不落坏文件
            writeAtomic(java.io.File(filesDir, PRIVATE_CORRECTION), raw)
            correctionImported = true
        }

        // best-effort 清 staging;app 通常无权删 /data/local/tmp(SELinux)→ 权威清理由 Valet 做。
        val wiped = staging.deleteRecursively() && !staging.exists()
        android.util.Log.i(
            "SettingsStore",
            "Valet 导入完成:$hostCount host" + (if (asrImported) " + ASR 凭证" else "") +
                (if (correctionImported) " + 纠错配置" else "") + " → 私有存储" +
                if (wiped) ",staging 已清" else "(staging 残留,需 Valet 清:adb shell rm -rf $STAGING_DIR)",
        )
    }

    /** 原子写:tmp → rename。防半成品(导入中途崩溃留下损坏文件)。 */
    private fun writeAtomic(target: java.io.File, text: String) {
        val tmp = java.io.File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) {
            target.delete()
            require(tmp.renameTo(target)) { "原子写失败: ${target.name}" }
        }
    }

    /** 读私钥文件并做基本校验:防 hosts.json 指向任意文件(路径遍历 / 读 /proc 等)。 */
    private fun readPemSafe(path: String): String {
        val kf = java.io.File(path)
        require(kf.exists() && kf.length() in 1..8192) { "key 文件不存在或过大: $path" }
        val text = kf.readText()
        require(text.contains("PRIVATE KEY")) { "不是合法私钥: $path" }
        return text
    }

    fun saveAsr(c: AsrConfig) {
        prefs.edit()
            .putString(K_ASR_PROVIDER, c.provider.name)
            .putString(K_ASR_APPID, c.appid)
            .putString(K_ASR_TOKEN, c.token)
            .putString(K_ASR_RESOURCE_ID, c.resourceId)
            .apply()
    }

    companion object {
        /** 代客安装(Valet)的 staging:adb push 落点。app 导入后整目录删除。 */
        const val STAGING_DIR = "/data/local/tmp/xreal_import"
        /** 导入后的私有真相来源(app 私有目录,reboot 不丢)。 */
        const val PRIVATE_HOSTS = "hosts.json"
        /** Valet 导入的 ASR 凭证(app 私有目录)。 */
        const val PRIVATE_ASR = "asr.json"
        /** Valet 导入的 LLM 纠错配置(app 私有目录,issue #16)。 */
        const val PRIVATE_CORRECTION = "correction.json"
        /** legacy 过渡期 host 配置(dev rig 用;adb push,reboot 清零,重跑 scripts/setup-mac-host.sh)。 */
        const val HOSTS_JSON = "/data/local/tmp/xreal_hosts.json"
        /** legacy 顶层 `proxies` 表无 localPort 时按序合成固定口的基址(目标契约是 host 内联 proxy.localPort)。 */
        private const val LEGACY_PROXY_PORT_BASE = 39000

        private const val K_SSH_HOST = "ssh_host"
        private const val K_SSH_PORT = "ssh_port"
        private const val K_SSH_USER = "ssh_user"
        private const val K_SSH_KEY_PEM = "ssh_key_pem"
        private const val K_SSH_STARTUP = "ssh_startup"

        private const val K_ASR_PROVIDER = "asr_provider"
        private const val K_ASR_APPID = "asr_appid"
        private const val K_ASR_TOKEN = "asr_token"
        private const val K_ASR_RESOURCE_ID = "asr_resource_id"
    }
}
