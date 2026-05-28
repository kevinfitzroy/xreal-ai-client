package io.github.kevinfitzroy.xrealclient

/**
 * 把 `tmux capture-pane -p` 的可见屏内容推断成 [ProjectSnapshot]。
 *
 * 纯函数、无 Android/IO 依赖 → 可在 JVM 单测里直接跑(见 AgentStatusDetectorTest)。
 *
 * ✅ 已对 **Claude Code v2.1.153**(Opus 4.7)实测校准(2026-05-28,task 0.3)。
 * 真快照存 src/test/resources/panes/,ClaudeCodePaneCalibrationTest 锁住 4 状态分类。
 * 关键结论:WORKING 靠底部 "esc to interrupt"(spinner 词随机:Osmosing/Hashing/Mulling…);
 * WAITING 靠 "Do you want to proceed?" + "❯ 1.";✻ 既在 spinner 也在完成行,不能只看它。
 * Claude Code 升版改 TUI 时,重抓快照 + 跑 calibration test 即可发现回归。
 */
object AgentStatusDetector {

    private const val PREVIEW_MAX = 120
    private const val WORK_SCAN = 6   // 只在底部若干行找 working spinner
    private const val WAIT_SCAN = 10  // 等待态:在底部若干行里找问句
    private val SPINNER_TIME = Regex("…\\s*\\(\\d+\\s*s\\)")

    fun detect(pane: String, type: ProjectType): ProjectSnapshot {
        // 1) 断开:tmux 报无 session / 连接错误(优先于一切)
        if (ClaudeCodeMarkers.NO_SESSION.any { pane.contains(it, ignoreCase = true) }) {
            return ProjectSnapshot(ProjectStatus.DISCONNECTED, "", "")
        }

        val nonEmpty = pane.lineSequence().map { it.trimEnd() }.filter { it.isNotBlank() }.toList()
        if (nonEmpty.isEmpty()) {
            return ProjectSnapshot(ProjectStatus.IDLE, "·", "")
        }

        // 2) SSH 类型不跑 agent 启发式:永远 idle,预览取最后一行
        if (type == ProjectType.SSH) {
            return ProjectSnapshot(ProjectStatus.IDLE, "·", lastSettledLine(nonEmpty))
        }

        // 3) 等待反馈(产品最该一眼认出的态)→ 优先于 working 判定,宁可多报不可漏报
        val waitTail = nonEmpty.takeLast(WAIT_SCAN)
        if (waitTail.any { line -> ClaudeCodeMarkers.WAITING.any { line.contains(it, ignoreCase = true) } }) {
            return ProjectSnapshot(ProjectStatus.WAITING_FEEDBACK, "?", waitingPreview(waitTail))
        }

        // 4) 工作中:底部若干行出现 spinner / "esc to interrupt" 等
        if (nonEmpty.takeLast(WORK_SCAN).any { line -> ClaudeCodeMarkers.WORKING.any { line.contains(it, ignoreCase = true) } }) {
            return ProjectSnapshot(ProjectStatus.WORKING, "↳", lastSettledLine(nonEmpty))
        }

        // 5) 其它 = 空闲(Claude 输入框等下一条指令 / 普通 shell prompt)
        return ProjectSnapshot(ProjectStatus.IDLE, "·", lastSettledLine(nonEmpty))
    }

    /** 等待态预览:优先底部以 '?' 结尾的问句行,否则命中 marker 的那行。 */
    private fun waitingPreview(tail: List<String>): String {
        val question = tail.lastOrNull { stripFrame(it).endsWith("?") }
            ?: tail.lastOrNull { line -> ClaudeCodeMarkers.WAITING.any { line.contains(it, ignoreCase = true) } }
        return clean(question ?: tail.last())
    }

    /**
     * 最后一个「稳定」内容行:跳过噪声行(spinner + working 提示行),取真正的内容。
     * 这样 working 态 preview 显示"它在做什么"(如 "Editing X.kt"),而不是每秒变的
     * spinner("✻ Thinking… (12s)")或固定提示("esc to interrupt")—— 避免列表抖动。
     */
    private fun lastSettledLine(nonEmpty: List<String>): String {
        // 跳过噪声行,且跳过 clean 后变空的行(纯 ──── 分隔线、空输入框 "❯")
        val pick = nonEmpty.lastOrNull { !isNoiseLine(it) && clean(it).isNotBlank() }
        return pick?.let { clean(it) } ?: ""
    }

    private fun isNoiseLine(line: String): Boolean {
        if (isSpinnerLine(line)) return true
        return ClaudeCodeMarkers.WORKING.any { line.contains(it, ignoreCase = true) }
    }

    private fun isSpinnerLine(line: String): Boolean {
        val t = line.trim()
        if (ClaudeCodeMarkers.SPINNER_GLYPHS.any { t.startsWith(it) }) return true
        return SPINNER_TIME.containsMatchIn(t)
    }

    /** 去 TUI 边框/提示符/bullet 字符 + 截断。 */
    private fun clean(line: String): String =
        stripFrame(line).take(PREVIEW_MAX)

    private fun stripFrame(line: String): String =
        line.trim().trim(
            '│', '╭', '╮', '╰', '╯', '─', '>', '❯', '*', '•', '⏺', '✻', '✢', '✶', '✽', ' ', '\t',
        ).trim()
}

/**
 * Claude Code TUI 签名串 —— 已对 v2.1.153 实测校准(见 ClaudeCodePaneCalibrationTest)。
 * 校准/升版适配只需改这一个 object,detect() 不动。
 */
object ClaudeCodeMarkers {
    /** tmux/SSH 侧表示 session 不在或连不上(HostClient 失败时也会塞 __NOSESSION__)。 */
    val NO_SESSION = listOf(
        "__NOSESSION__", "can't find session", "no server running",
        "no sessions", "error connecting",
    )

    /** Claude Code 暂停、等用户确认/选择。"Do you want to proceed?" + "❯ 1." 实测命中。 */
    val WAITING = listOf(
        "Do you want to proceed", "Do you want to", "(y/n)", "(Y/n)", "(y/N)", "[y/N]", "[Y/n]",
        "❯ 1.", "❯ 2.", "1. Yes", "Press Enter to continue", "Would you like",
    )

    /**
     * Claude Code 正在跑。**可靠信号是 "esc to interrupt"**(实测:spinner 词随机,
     * 见过 Osmosing/Hashing/Mulling/Crunched/Doing,不能靠词判定)。其余词仅作冗余兜底。
     */
    val WORKING = listOf(
        "esc to interrupt", "to interrupt)", "Thinking…", "Running…",
        "Working…", "Generating…", "Compacting…",
    )

    /**
     * spinner 行的起始 glyph(抗抖动跳过)。实测 v2.1.153 用 ✻✢✶✽ 轮换。
     * 注意:不含 ⏺ —— 那是已完成动作的 bullet(稳定行,适合做 preview)。
     */
    val SPINNER_GLYPHS = listOf("✻", "✢", "✶", "✽")
}
