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

    /** 物化某 host 的私钥到 keyDir,返回路径(manifest/jump 共用)。 */
    private fun keyPathFor(h: HostConfig): String =
        File(keyDir, "manifest_${h.name}.pem").apply {
            writeText(h.ssh.privateKeyPem); setReadable(false, false); setReadable(true, true)
        }.absolutePath

    private fun clientFor(h: HostConfig, jump: JumpSpec?): HostClient = clients.getOrPut(h.name) {
        HostClient(h.ssh.host, h.ssh.port, h.ssh.user, keyPathFor(h), knownHostsFile, jump)
    }

    /** 阻塞(在后台线程调):逐 host **串行**拉 manifest,返回更新 projects 后的 HostConfig。无 basePath / 拉取失败的 host 原样返回。
     *  串行 = 任一 host 不可达(如 VPN 关时的内网 host)会卡满其 connect 超时(8s)并拖住后面所有 host →
     *  每个 host 单独打耗时,慢在哪个 host 一眼可见。 */
    fun fetch(hosts: List<HostConfig>): List<HostConfig> {
      val byName = hosts.associateBy { it.name }
      return hosts.map { h ->
        if (h.basePath.isBlank()) return@map h
        val jump = h.via?.let { byName[it] }?.let { jh ->
            JumpSpec(jh.ssh.host, jh.ssh.port, jh.ssh.user, keyPathFor(jh), knownHostsFile)
        }
        val t0 = System.currentTimeMillis()
        val raw = clientFor(h, jump).catFile("${h.basePath.trimEnd('/')}/.xreal/projects.json")
        AppLog.i("ManifestFetcher", "${h.name} manifest ${System.currentTimeMillis() - t0}ms ${if (raw == null) "(失败/超时)" else "ok"}")
        val projects = raw?.let { parseManifest(it, h.name) }
        if (projects == null) h else h.copy(projects = projects)
      }
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
                    if (p.has("hotwords") && p.optJSONArray("hotwords") == null)
                        android.util.Log.w("ManifestFetcher", "$hostName: '$session' 的 hotwords 不是 JSON 数组,已忽略(应为 [\"词1\",\"词2\"])")
                    val hotwords = p.optJSONArray("hotwords")
                        ?.let { hw -> (0 until hw.length()).map { hw.getString(it) } } ?: emptyList()
                    val cfg = if (type != null && session.isNotBlank())
                        ProjectConfig(session, p.optString("name", session), type, hotwords) else null
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
