package io.github.kevinfitzroy.xrealclient

/**
 * Agent Deck 数据模型 —— Host(一级)→ Project(二级)。
 *
 * 配置(HostConfig/ProjectConfig)目前只是内存模型:还没有管理 host 列表的 UI,
 * 所以 [SettingsStore.loadHosts] 暂时返回 emptyList()。等 task 0.3(真 tmux 链路)
 * + host 列表录入 UI 落地后再持久化。
 *
 * 运行时状态(ProjectStatus/ProjectSnapshot)由 [AgentStatusDetector] 从
 * `tmux capture-pane -p` 输出推断,[StatusPoller] 周期性刷新并推给 WebView 列表。
 */

enum class ProjectType { SSH, CLAUDE, AGENT, MAESTRO }   // MAESTRO = host orchestrator(每 host 一个,pin 首位)

enum class ProjectStatus { WORKING, WAITING_FEEDBACK, IDLE, DISCONNECTED }

/** 一个远端 project = 一个持久 tmux session + 类型。 */
data class ProjectConfig(
    val sessionName: String,
    val displayName: String,
    val type: ProjectType,
) {
    /** session 名只允许进 shell 命令的安全字符(HostClient 会拼进 exec 脚本)。 */
    fun isSessionNameSafe(): Boolean = SAFE_SESSION.matches(sessionName)

    companion object {
        private val SAFE_SESSION = Regex("[A-Za-z0-9_.-]+")
    }
}

/** 一台 host = SSH 接入参数 + 该 host 上的 project 列表。 */
data class HostConfig(
    val name: String,
    val addr: String,
    val ssh: SshConfig,
    val projects: List<ProjectConfig>,
)

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
    ProjectType.AGENT -> "agent"
    ProjectType.MAESTRO -> "maestro"
}
