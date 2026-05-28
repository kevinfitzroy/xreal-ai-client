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
    val appid: String = "",
    val token: String = "",
    val cluster: String = "",
) {
    fun isVolcConfigured(): Boolean =
        provider == AsrProvider.VOLC && appid.isNotBlank() && token.isNotBlank()
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

    fun loadAsr(): AsrConfig = AsrConfig(
        provider = runCatching {
            AsrProvider.valueOf(prefs.getString(K_ASR_PROVIDER, AsrProvider.MOCK.name)!!)
        }.getOrDefault(AsrProvider.MOCK),
        appid = prefs.getString(K_ASR_APPID, "") ?: "",
        token = prefs.getString(K_ASR_TOKEN, "") ?: "",
        cluster = prefs.getString(K_ASR_CLUSTER, "") ?: "",
    )

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
        val arr = org.json.JSONArray(f.readText())
        (0 until arr.length()).map { i ->
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
                        )
                    }
                },
                basePath = o.optString("basePath", ""),
            )
        }
    } catch (e: Exception) {
        android.util.Log.w("SettingsStore", "parseHosts 解析 ${f.path} 失败: ${e.message}")
        emptyList()
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
        if (!stagedHosts.exists()) return

        val keysDir = java.io.File(filesDir, "keys").apply { mkdirs() }
        // 清理上次崩溃残留的半成品(原子写的 .tmp)
        filesDir.listFiles { _, n -> n.endsWith(".tmp") }?.forEach { it.delete() }
        keysDir.listFiles { _, n -> n.endsWith(".tmp") }?.forEach { it.delete() }

        val arr = org.json.JSONArray(stagedHosts.readText())
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
        writeAtomic(java.io.File(filesDir, PRIVATE_HOSTS), arr.toString())
        // best-effort 清 staging;app 通常无权删 /data/local/tmp(SELinux)→ 权威清理由 Valet 做。
        val wiped = staging.deleteRecursively() && !staging.exists()
        android.util.Log.i(
            "SettingsStore",
            "Valet 导入完成:${arr.length()} host → 私有存储" +
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
            .putString(K_ASR_CLUSTER, c.cluster)
            .apply()
    }

    companion object {
        /** 代客安装(Valet)的 staging:adb push 落点。app 导入后整目录删除。 */
        const val STAGING_DIR = "/data/local/tmp/xreal_import"
        /** 导入后的私有真相来源(app 私有目录,reboot 不丢)。 */
        const val PRIVATE_HOSTS = "hosts.json"
        /** legacy 过渡期 host 配置(dev rig 用;adb push,reboot 清零,重跑 scripts/setup-mac-host.sh)。 */
        const val HOSTS_JSON = "/data/local/tmp/xreal_hosts.json"

        private const val K_SSH_HOST = "ssh_host"
        private const val K_SSH_PORT = "ssh_port"
        private const val K_SSH_USER = "ssh_user"
        private const val K_SSH_KEY_PEM = "ssh_key_pem"
        private const val K_SSH_STARTUP = "ssh_startup"

        private const val K_ASR_PROVIDER = "asr_provider"
        private const val K_ASR_APPID = "asr_appid"
        private const val K_ASR_TOKEN = "asr_token"
        private const val K_ASR_CLUSTER = "asr_cluster"
    }
}
