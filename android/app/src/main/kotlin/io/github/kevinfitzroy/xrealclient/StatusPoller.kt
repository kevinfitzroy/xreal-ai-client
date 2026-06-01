package io.github.kevinfitzroy.xrealclient

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 周期性探测所有 host 的所有 project 状态,序列化成 WebView 列表能吃的 JSON,回调推给 UI。
 *
 * - host 列表为空 → [start] 直接返回,**不空转**(没配置时 WebView 保留 index.html 的 mock)。
 * - 每 host 一个复用的 [HostClient](O(hosts) 抓取);异常自愈(下次 poll 重连)。
 * - 私钥 PEM 物化到 [keyDir],一个 host 一个文件。
 */
class StatusPoller(
    private val hosts: List<HostConfig>,
    private val keyDir: File,
    private val knownHostsFile: File?,
    private val intervalMs: Long = 5000,
    /** 收到整批 hosts JSON(数组字符串),调用方负责切到 UI 线程喂给 WebView。 */
    private val onUpdate: (hostsJson: String) -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val clients = HashMap<String, HostClient>()
    private var job: Job? = null

    fun start() {
        if (hosts.isEmpty() || job != null) return
        job = scope.launch {
            while (isActive) {
                runCatching { onUpdate(pollOnce()) }
                delay(intervalMs)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        clients.values.forEach { runCatching { it.close() } }
        clients.clear()
    }

    /** 终态拆除:停 poll + 取消 scope(Activity onDestroy 调一次)。stop() 后 poller 不可再 start。 */
    fun shutdown() {
        stop()
        scope.cancel()
    }

    private fun keyPathFor(h: HostConfig): String =
        File(keyDir, "host_${h.name}.pem").apply {
            writeText(h.ssh.privateKeyPem)
            setReadable(false, false); setReadable(true, true)
        }.absolutePath

    private fun clientFor(h: HostConfig, jump: JumpSpec?, directProxy: ProxyConfig?): HostClient = clients.getOrPut(h.name) {
        HostClient(
            host = h.ssh.host, port = h.ssh.port, user = h.ssh.user,
            privateKeyPath = keyPathFor(h), knownHostsFile = knownHostsFile, jump = jump,
            proxy = directProxy,   // SSH-over-443:effectiveProxy 归属(直连用自己;jump 时 null,proxy 在 JumpSpec)
        )
    }

    private fun pollOnce(): String {
        val byName = hosts.associateBy { it.name }
        val arr = JSONArray()
        for (h in hosts) {
            val eff = h.effectiveProxy(hosts)   // 生效 proxy = 实际拨公网那一跳(SPEC §5.1 单一归属)
            val jump = h.via?.let { byName[it] }?.let { jh ->
                JumpSpec(jh.ssh.host, jh.ssh.port, jh.ssh.user, keyPathFor(jh), knownHostsFile, eff)
            }
            val panes = clientFor(h, jump, if (h.via == null) eff else null).captureAll(h.projects.map { it.sessionName })
            val snaps = h.projects.map { p ->
                p to AgentStatusDetector.detect(panes[p.sessionName] ?: HostClient.NO_SESSION_SENTINEL, p.type)
            }
            android.util.Log.i("StatusPoller", "${h.name}: " + snaps.joinToString { "${it.first.sessionName}=${it.second.status}" })
            arr.put(hostJson(h, snaps, eff?.name ?: ""))
        }
        return arr.toString()
    }

    /** JSON 形状的唯一来源(对齐 index.html 的 setHosts/HOSTS):{name,addr,up,projects:[...]}。 */
    companion object {
        private fun projectJson(
            p: ProjectConfig, s: ProjectSnapshot, loading: Boolean = false,
            state: String? = null, since: Long = 0,   // hooks 实时状态(working/waiting/disconnected/unknown)+ 进入时刻
        ): JSONObject {
            val o = JSONObject()
                .put("session", p.sessionName)   // JS 端 openProject 的主键(name 可能重复)
                .put("name", p.displayName)
                .put("type", p.type.jsKey())
                .put("status", s.status.jsKey())
                .put("loading", loading)         // 首屏冷加载:状态徽章显示"加载中"转圈,manifest 拉到后变真状态
                .put("age", "")
            if (state != null) o.put("state", state).put("since", since)   // JS 优先用 state(+since 算时长)
            o.put(
                "preview",
                if (s.preview.isBlank()) JSONObject.NULL
                else JSONObject()
                    .put("glyph", s.glyph)
                    .put("text", s.preview)
                    .put("cur", s.status == ProjectStatus.WORKING),
            )
            return o
        }

        /** UI 上显示的 SSH-over-443 代理标签(SPEC §5.1)= 生效 proxy 名(实际拨公网那一跳:直连用自己、
         *  经 via 用跳板的)。归属规则的单一真相在 [effectiveProxy]。无代理 → 空。 */
        private fun hostProxyLabel(h: HostConfig, all: List<HostConfig>): String =
            h.effectiveProxy(all)?.name ?: ""

        private fun hostJson(h: HostConfig, snaps: List<Pair<ProjectConfig, ProjectSnapshot>>, proxyLabel: String, loading: Boolean = false): JSONObject {
            val projects = JSONArray()
            for ((p, s) in snaps) projects.put(projectJson(p, s, loading))
            val up = snaps.any { it.second.status != ProjectStatus.DISCONNECTED }
            return JSONObject().put("name", h.name).put("addr", h.addr).put("up", up)
                .put("proxy", proxyLabel).put("projects", projects)
        }

        /**
         * 真实 host/project 静态枚举,并并入 hooks 实时状态([statusByHost])。
         * 每 project 的 state:host 不可达([reachable] 非 null 且不含该 host)→ disconnected;
         * 否则 status.json 有 → 用之;没有 → unknown(用户拍板:不清楚就 unknown,不抓屏兜底)。
         * [reachable] = null 表示"未探测"(首屏 seed / poll),此时 state=null,JS 走 loading / on-duty 旧逻辑。
         */
        fun staticListJson(
            hosts: List<HostConfig>,
            loading: Boolean = false,
            statusByHost: Map<String, Map<String, SessionState>> = emptyMap(),
            reachable: Set<String>? = null,
        ): String {
            val arr = JSONArray()
            val idle = ProjectSnapshot(ProjectStatus.IDLE, "", "")
            for (h in hosts) {
                val hostStatus = statusByHost[h.name] ?: emptyMap()
                val unreachable = reachable != null && h.basePath.isNotBlank() && h.name !in reachable
                val projects = JSONArray()
                for (p in h.projects) {
                    val live: SessionState? = hostStatus[p.sessionName]
                    val state: String? = when {
                        reachable == null -> null               // 未探测:不给 state,JS 走旧逻辑
                        unreachable -> "disconnected"
                        else -> live?.state ?: "unknown"
                    }
                    projects.put(projectJson(p, idle, loading, state, live?.since ?: 0))
                }
                arr.put(JSONObject().put("name", h.name).put("addr", h.addr).put("up", !unreachable)
                    .put("proxy", hostProxyLabel(h, hosts)).put("projects", projects))
            }
            return arr.toString()
        }
    }
}
