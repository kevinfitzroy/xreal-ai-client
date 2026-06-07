package io.github.kevinfitzroy.xrealclient

/**
 * Agent Deck 数据模型 —— Host(一级)→ Project(二级)。
 *
 * 配置由 [SettingsStore.loadHosts] 从 hosts.json 读(Valet 代客安装 → 私有存储;
 * **无设置 UI 是刻意设计**)。project 列表的真相来源是 [ManifestFetcher] 从各 host
 * 拉的 manifest;内网 host 经 [HostConfig.via] 跳板多跳到达。
 *
 * 卡片**运行时状态**当前走 **Claude Code hooks**:hook 写 `<base>/.xreal/status.json`,
 * [ManifestFetcher] 一次性 cat 后并入列表(state:working/waiting/disconnected/unknown
 * + since 算时长)。本文件的 [ProjectStatus]/[ProjectSnapshot] 属于**抓屏检测路径**
 * ([AgentStatusDetector] + [StatusPoller] 周期 `capture-pane`),该路径搁置 P2
 * ([FleetFeatures.LIVE_STATUS]=false),当前不走。
 */

enum class ProjectType { SSH, CLAUDE, CODEX, AGENT, MAESTRO }   // MAESTRO = host orchestrator(每 host 一个,pin 首位);CODEX = OpenAI Codex CLI(与 CLAUDE 同构,#18)

/** AI agent 类(对话端是 Claude Code,可领会语音意图);SSH 是裸 shell。决定语音注入是否加 🎤 marker。 */
fun ProjectType.isAiAgent(): Boolean = this != ProjectType.SSH

enum class ProjectStatus { WORKING, WAITING_FEEDBACK, IDLE, DISCONNECTED }

/** 一个远端 project = 一个持久 tmux session + 类型。 */
data class ProjectConfig(
    val sessionName: String,
    val displayName: String,
    val type: ProjectType,
    /** 该 project 的语音热词(manifest 带,可空)。与 [Hotwords.BASE] 合并后喂 ASR。 */
    val hotwords: List<String> = emptyList(),
) {
    /** session 名只允许进 shell 命令的安全字符(HostClient 会拼进 exec 脚本)。 */
    fun isSessionNameSafe(): Boolean = SAFE_SESSION.matches(sessionName)

    companion object {
        private val SAFE_SESSION = Regex("[A-Za-z0-9_.-]+")
    }
}

/** host 级 SSH-over-443 隧道(SPEC.md §5.1)。host 内联 `proxy{name,localPort,url}`。
 *  [localPort] = 本机 127.0.0.1 固定监听口(整份 host 配置内必须唯一,见 [localPortConflict]);
 *  [url] = 标准 `vmess://` 分享链接。 */
data class ProxyConfig(
    val name: String,
    val localPort: Int,
    val url: String,
)

/** 一台 host = SSH 接入参数 + base path + 该 host 上的 project 列表。 */
data class HostConfig(
    val name: String,
    val addr: String,
    val ssh: SshConfig,
    val projects: List<ProjectConfig>,
    /** Maestro 工作根目录;manifest 在 `<basePath>/.xreal/projects.json`。空 = 不 live-fetch(仅用 seed)。 */
    val basePath: String = "",
    /** 多跳:经哪个 host 跳板(值 = 另一 host 的 [name])。非空 → SSH 经该跳板 ProxyJump 到本 host。
     *  典型:OPS(AWS 内网,只 VPN 可达)`via = "TK-ALIYUN"`,由挂着 OpenVPN 的 TK 转发。 */
    val via: String? = null,
    /** SSH-over-443:本 host 内联的 proxy(SPEC.md §5.1;无则 null=直连)。
     *  归属规则(见 [effectiveProxy]):本 host 作为**跳板被别人 via** 时,此 proxy 用于那条外层拨号;
     *  本 host 自己有 [via] 时此字段被忽略(由跳板的 proxy 决定)。 */
    val proxy: ProxyConfig? = null,
)

/**
 * **生效 proxy = 实际拨公网那一跳的 proxy**(SPEC §5.1 归属规则的单一真相;badge + 连接注入共用)。
 * - host 有 [HostConfig.via] → 用**跳板**的 proxy(拨公网的是跳板;host 自己的 proxy 被忽略)。
 * - host 无 via → 用自己的 proxy。
 * - 无 → null(直连)。
 * [all] 用于按 via 名查跳板 host。调用方据此派生:`directProxy = if(via==null) effective else null`;
 * jump 场景把 effective 塞进 [JumpSpec.proxy](= 跳板自己的 proxy)。
 */
fun HostConfig.effectiveProxy(all: List<HostConfig>): ProxyConfig? =
    if (via == null) proxy else all.firstOrNull { it.name == via }?.proxy

/**
 * 校验 [localPort] 在整份配置内唯一(SPEC §5.1 硬约束)。返回冲突描述(非 null=有冲突),无冲突 → null。
 * 调用方(SettingsStore)据此 **fail closed**:冲突 = 拒绝整份配置,**绝不悄悄退回直连**(直连的 :22 正是被卡的那条)。
 * 同名 proxy 复用(多个 host 引用同一条)不算冲突;两个不同 name 撞同一 localPort 才算。
 */
fun localPortConflict(hosts: List<HostConfig>): String? {
    val seen = HashMap<Int, String>()
    for (p in hosts.mapNotNull { it.proxy }.distinctBy { it.name }) {
        val prev = seen.put(p.localPort, p.name)
        if (prev != null && prev != p.name)
            return "localPort ${p.localPort} 被 proxy '$prev' 和 '${p.name}' 同时占用"
    }
    return null
}

/** detect() 的产出:状态 + 列表预览(glyph + 一行文本)。preview 空 = 列表不显示预览行。 */
data class ProjectSnapshot(
    val status: ProjectStatus,
    val glyph: String,
    val preview: String,
)

/** JSON key 与 WebView 端 STATUS / ICONS 表对齐(不改 JS,在这里让步)。 */
fun ProjectStatus.jsKey(): String = when (this) {
    ProjectStatus.WORKING -> "work"
    ProjectStatus.WAITING_FEEDBACK -> "wait"
    ProjectStatus.IDLE -> "idle"
    ProjectStatus.DISCONNECTED -> "offline"
}

fun ProjectType.jsKey(): String = when (this) {
    ProjectType.SSH -> "ssh"
    ProjectType.CLAUDE -> "claude"
    ProjectType.CODEX -> "codex"
    ProjectType.AGENT -> "agent"
    ProjectType.MAESTRO -> "maestro"
}

/** 字符串 → ProjectType,未知/未来 type 归 SSH 兜底(SPEC §3:别丢弃整条 project)。大小写不敏感。 */
fun parseProjectType(raw: String?): ProjectType =
    raw?.trim()?.uppercase()?.let { s -> ProjectType.entries.firstOrNull { it.name == s } } ?: ProjectType.SSH
