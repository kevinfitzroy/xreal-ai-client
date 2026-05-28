package io.github.kevinfitzroy.xrealclient

import org.json.JSONObject
import java.io.File

/**
 * 从各 host 的 `<basePath>/.xreal/projects.json`(Maestro 维护)拉项目清单(P1.1c)。
 * per-host 复用 [HostClient](连接惰性、断了自重连)。失败 / 缺失 / 版本不符 → **保留传入的当前 projects**,
 * 绝不把列表清空(调用方据此做"内容不变不重推")。
 */
class ManifestFetcher(
    private val keyDir: File,
    private val knownHostsFile: File?,
) {
    private val clients = HashMap<String, HostClient>()

    private fun clientFor(h: HostConfig): HostClient = clients.getOrPut(h.name) {
        val keyFile = File(keyDir, "manifest_${h.name}.pem").apply {
            writeText(h.ssh.privateKeyPem); setReadable(false, false); setReadable(true, true)
        }
        HostClient(h.ssh.host, h.ssh.port, h.ssh.user, keyFile.absolutePath, knownHostsFile)
    }

    /** 阻塞(在后台线程调):逐 host 拉 manifest,返回更新 projects 后的 HostConfig。无 basePath / 拉取失败的 host 原样返回。 */
    fun fetch(hosts: List<HostConfig>): List<HostConfig> = hosts.map { h ->
        if (h.basePath.isBlank()) return@map h
        val raw = clientFor(h).catFile("${h.basePath.trimEnd('/')}/.xreal/projects.json")
        val projects = raw?.let { parseManifest(it, h.name) }
        if (projects == null) h else h.copy(projects = projects)
    }

    fun close() {
        clients.values.forEach { runCatching { it.close() } }
        clients.clear()
    }

    companion object {
        /** manifest JSON → projects 列表;version 非 1 / 解析失败 → null(调用方保留 seed)。非法项目跳过。 */
        fun parseManifest(text: String, hostName: String): List<ProjectConfig>? = try {
            val o = JSONObject(text)
            val ver = o.optInt("version", 0)
            if (ver != 1) {
                android.util.Log.w("ManifestFetcher", "$hostName: manifest version=$ver 不支持,忽略")
                null
            } else {
                val arr = o.getJSONArray("projects")
                (0 until arr.length()).mapNotNull { i ->
                    val p = arr.getJSONObject(i)
                    val session = p.optString("session")
                    val type = runCatching { ProjectType.valueOf(p.optString("type").uppercase()) }.getOrNull()
                    val cfg = if (type != null && session.isNotBlank())
                        ProjectConfig(session, p.optString("name", session), type) else null
                    if (cfg == null || !cfg.isSessionNameSafe()) {
                        android.util.Log.w("ManifestFetcher", "$hostName: 跳过非法项目 session='$session' type='${p.optString("type")}'")
                        null
                    } else cfg
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("ManifestFetcher", "$hostName: manifest 解析失败: ${e.message}")
            null
        }
    }
}
