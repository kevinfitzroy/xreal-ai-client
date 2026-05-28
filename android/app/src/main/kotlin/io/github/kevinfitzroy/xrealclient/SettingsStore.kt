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
     * Agent Deck 的 host/project 列表。
     *
     * 过渡期持久化(还没录入 UI):读 [HOSTS_JSON](adb push 进来)。schema:
     * `[{ "name","addr","host","port","user","keyPath","projects":[{"session","name","type"}] }]`
     * keyPath 指向设备上的私钥文件(由 [readPemSafe] 校验后读成 PEM)。文件不存在 → 空列表(走 mock)。
     */
    fun loadHosts(): List<HostConfig> {
        val f = java.io.File(HOSTS_JSON)
        if (!f.exists()) return emptyList()
        return try {
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
                )
            }
        } catch (e: Exception) {
            android.util.Log.w("SettingsStore", "loadHosts 解析 $HOSTS_JSON 失败: ${e.message}")
            emptyList()
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
        /** 过渡期 host 配置(adb push;重启清零,reboot 后重跑 scripts/setup-mac-host.sh)。 */
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
