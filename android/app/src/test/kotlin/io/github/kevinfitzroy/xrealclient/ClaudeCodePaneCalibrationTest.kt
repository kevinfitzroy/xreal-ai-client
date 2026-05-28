package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 用**真实** `tmux capture-pane -p` 快照校准 [AgentStatusDetector]。
 *
 * 样本抓自 Claude Code v2.1.153(Opus 4.7)在 Mac 上经 SSH + tmux 跑真任务时,
 * 存于 src/test/resources/panes/。这把 [ClaudeCodeMarkers] 从"假设"变成"对 v2.1.153 实测"。
 *
 * 关键校准发现(2026-05-28):
 *   - WORKING 的可靠信号是底部 "esc to interrupt" —— spinner 的**词是随机的**
 *     (实测见过 Osmosing / Hashing / Mulling / Crunched / Doing),不能靠特定词判定。
 *   - WAITING 权限框确为 "Do you want to proceed?" + "❯ 1. Yes"(marker 命中)。
 *   - "esc to cancel"(权限框底部)≠ "esc to interrupt"(working),不会误判。
 *   - ✻ 既出现在 active spinner 也出现在完成行("✻ Crunched for 45s"),所以
 *     状态判定不能只看 ✻,要看有没有 "esc to interrupt"。
 */
class ClaudeCodePaneCalibrationTest {

    private fun pane(name: String): String =
        javaClass.getResourceAsStream("/panes/$name")?.bufferedReader()?.readText()
            ?: error("缺少测试样本 /panes/$name")

    @Test fun real_claude_idle_launch() {
        assertEquals(ProjectStatus.IDLE, AgentStatusDetector.detect(pane("claude_idle.txt"), ProjectType.CLAUDE).status)
    }

    @Test fun real_claude_working() {
        // "✽ Doing…" + "esc to interrupt"
        assertEquals(ProjectStatus.WORKING, AgentStatusDetector.detect(pane("claude_working.txt"), ProjectType.CLAUDE).status)
    }

    @Test fun real_claude_waiting_permission_prompt() {
        val s = AgentStatusDetector.detect(pane("claude_waiting.txt"), ProjectType.CLAUDE)
        assertEquals(ProjectStatus.WAITING_FEEDBACK, s.status)
        assertTrue("等待态 preview 应是问句: '${s.preview}'", s.preview.contains("proceed", ignoreCase = true))
    }

    @Test fun real_bash_session_is_ssh_idle() {
        assertEquals(ProjectStatus.IDLE, AgentStatusDetector.detect(pane("ssh_idle.txt"), ProjectType.SSH).status)
    }
}
