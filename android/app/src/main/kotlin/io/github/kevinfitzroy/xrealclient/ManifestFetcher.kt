package io.github.kevinfitzroy.xrealclient

import org.json.JSONObject
import java.io.File

/** 某 session 的实时状态(Claude Code hooks 写的)。[since] = 进入该状态的服务端 Unix 秒;客户端算 age。 */
data class SessionState(val state: String, val since: Long)

/** [fetch] 的产出:各 host 更新 projects 后的配置 + 各 host 的 session→状态映射(来自 status.json)+ 本次可达的 host。 */
data class FetchResult(
    val hosts: List<HostConfig>,
    val status: Map<String, Map<String, SessionState>>,   // hostName → (session → state)
    val reachable: Set<String>,                            // 本次成功 cat 到 manifest 的 host(否则判 disconnected)
)

/**
 * 从各 host 的 `<basePath>/.xreal/projects.json`(Maestro 维护)拉项目清单(P1.1c)+
 * `<basePath>/.xreal/status.json`(Claude Code hooks 写的实时状态)。
 * per-host 复用 [HostClient](连接惰性、断了自重连)。失败 / 缺失 / 版本不符 → **保留传入的当前 projects**,
 * 绝不把列表清空(调用方据此做"内容不变不重推")。status.json 缺失 → 空 map → app 端该 session 判 unknown。
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

    private fun clientFor(h: HostConfig, jump: JumpSpec?, directProxy: ProxyConfig?): HostClient = clients.getOrPut(h.name) {
        // SSH-over-443:effectiveProxy 归属(直连用自己;jump 时 null,proxy 在 JumpSpec 里)。
        HostClient(h.ssh.host, h.ssh.port, h.ssh.user, keyPathFor(h), knownHostsFile, jump, directProxy)
    }

    /** 阻塞(在后台线程调):逐 host **串行**拉 manifest,返回更新 projects 后的 HostConfig。无 basePath / 拉取失败的 host 原样返回。
     *  串行 = 任一 host 不可达(如 VPN 关时的内网 host)会卡满其 connect 超时(8s)并拖住后面所有 host →
     *  每个 host 单独打耗时,慢在哪个 host 一眼可见。 */
    fun fetch(hosts: List<HostConfig>): FetchResult {
      val byName = hosts.associateBy { it.name }
      val statusByHost = HashMap<String, Map<String, SessionState>>()
      val reachable = HashSet<String>()
      val outHosts = hosts.map { h ->
        if (h.basePath.isBlank()) return@map h
        val eff = h.effectiveProxy(hosts)   // 生效 proxy = 实际拨公网那一跳(SPEC §5.1 单一归属)
        val jump = h.via?.let { byName[it] }?.let { jh ->
            JumpSpec(jh.ssh.host, jh.ssh.port, jh.ssh.user, keyPathFor(jh), knownHostsFile, eff)
        }
        val client = clientFor(h, jump, if (h.via == null) eff else null)
        val base = h.basePath.trimEnd('/')
        val t0 = System.currentTimeMillis()
        val raw = client.catFile("$base/.xreal/projects.json")
        AppLog.i("ManifestFetcher", "${h.name} manifest ${System.currentTimeMillis() - t0}ms ${if (raw == null) "(失败/超时)" else "ok"}")
        if (raw != null) reachable.add(h.name)   // cat 成功 = host 可达;失败 → 不在集里 → 判 disconnected
        // 同连接顺手拉 status.json(hooks 写的实时状态;缺失 → 空 → app 判 unknown)
        statusByHost[h.name] = parseStatus(client.catFile("$base/.xreal/status.json"))
        val projects = raw?.let { parseManifest(it, h.name) }
        if (projects == null) h else h.copy(projects = projects)
      }
      return FetchResult(outHosts, statusByHost, reachable)
    }

    fun close() {
        clients.values.forEach { runCatching { it.close() } }
        clients.clear()
    }

    companion object {
        /** status.json(`{"timestamp":N,"sessions":[{"session","state","since"}]}`)→ session→状态。缺失/坏 → 空。 */
        fun parseStatus(text: String?): Map<String, SessionState> {
            if (text.isNullOrBlank()) return emptyMap()
            return try {
                val arr = JSONObject(text).optJSONArray("sessions") ?: return emptyMap()
                (0 until arr.length()).mapNotNull { i ->
                    val s = arr.getJSONObject(i)
                    val session = s.optString("session"); val state = s.optString("state")
                    if (session.isBlank() || state.isBlank()) null
                    else session to SessionState(state, s.optLong("since", 0))
                }.toMap()
            } catch (e: Exception) {
                android.util.Log.w("ManifestFetcher", "status.json 解析失败: ${e.message}"); emptyMap()
            }
        }

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
                    val type = parseProjectType(p.optString("type"))   // 未知 type 归 SSH 兜底(SPEC §3),不丢整条
                    if (p.has("hotwords") && p.optJSONArray("hotwords") == null)
                        android.util.Log.w("ManifestFetcher", "$hostName: '$session' 的 hotwords 不是 JSON 数组,已忽略(应为 [\"词1\",\"词2\"])")
                    val hotwords = p.optJSONArray("hotwords")
                        ?.let { hw -> (0 until hw.length()).map { hw.getString(it) } } ?: emptyList()
                    val cfg = if (session.isNotBlank())
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
