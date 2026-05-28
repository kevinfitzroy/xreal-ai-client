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

    fun saveAsr(c: AsrConfig) {
        prefs.edit()
            .putString(K_ASR_PROVIDER, c.provider.name)
            .putString(K_ASR_APPID, c.appid)
            .putString(K_ASR_TOKEN, c.token)
            .putString(K_ASR_CLUSTER, c.cluster)
            .apply()
    }

    companion object {
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
