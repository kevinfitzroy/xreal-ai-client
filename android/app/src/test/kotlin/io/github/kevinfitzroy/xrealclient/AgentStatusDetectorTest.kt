package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 验证 [AgentStatusDetector] 的【管道】:优先级、preview 抽取、抗抖动、SSH 旁路。
 *
 * ⚠️ 这里的 pane 样本是 placeholder(对齐 [ClaudeCodeMarkers] 的假设串),不是真
 * Claude Code 输出。所以「绿 = 测对了启发式」是错觉 —— 测的是 parser 跑得通 + 分支正确。
 * task 0.3 抓到真快照后,把样本换成真数据,这些断言才有「能正确分类真 agent」的含义。
 */
class AgentStatusDetectorTest {

    @Test fun working_when_spinner_and_interrupt_hint() {
        val pane = """
            ⏺ Editing TerminalBridge.kt — wiring channel swap
            ✻ Thinking… (12s)
              (esc to interrupt)
        """.trimIndent()
        val s = AgentStatusDetector.detect(pane, ProjectType.CLAUDE)
        assertEquals(ProjectStatus.WORKING, s.status)
        // 抗抖动:preview 不能是 spinner 行
        assertTrue("preview 不应是 spinner 行: '${s.preview}'", "(12s)" !in s.preview && "esc to interrupt" !in s.preview)
        assertEquals("Editing TerminalBridge.kt — wiring channel swap", s.preview)
    }

    @Test fun waiting_when_proceed_question_with_options() {
        val pane = """
            ╭─ Bash command ──────────────╮
            │ rm -rf build/               │
            ╰─────────────────────────────╯
            Do you want to proceed?
            ❯ 1. Yes
              2. No
        """.trimIndent()
        val s = AgentStatusDetector.detect(pane, ProjectType.CLAUDE)
        assertEquals(ProjectStatus.WAITING_FEEDBACK, s.status)
        assertEquals("?", s.glyph)
        assertEquals("Do you want to proceed?", s.preview)
    }

    @Test fun waiting_when_yn_prompt() {
        val pane = """
            Applying migration 0042_add_column.sql
            Continue? (y/n)
        """.trimIndent()
        val s = AgentStatusDetector.detect(pane, ProjectType.CLAUDE)
        assertEquals(ProjectStatus.WAITING_FEEDBACK, s.status)
    }

    @Test fun waiting_beats_working_when_both_present() {
        // 若 spinner 残影与确认框同屏,等待反馈优先(产品最该一眼认出)
        val pane = """
            ✻ Thinking… (3s)
            Do you want to proceed?
            ❯ 1. Yes
        """.trimIndent()
        val s = AgentStatusDetector.detect(pane, ProjectType.CLAUDE)
        assertEquals(ProjectStatus.WAITING_FEEDBACK, s.status)
    }

    @Test fun idle_when_claude_input_box_no_markers() {
        val pane = """
            ⏺ Done. Updated 3 files.
            ╭──────────────────────────────────────╮
            │ >                                     │
            ╰──────────────────────────────────────╯
              ? for shortcuts
        """.trimIndent()
        val s = AgentStatusDetector.detect(pane, ProjectType.CLAUDE)
        assertEquals(ProjectStatus.IDLE, s.status)
    }

    @Test fun disconnected_on_nosession_sentinel() {
        val s = AgentStatusDetector.detect("__NOSESSION__", ProjectType.CLAUDE)
        assertEquals(ProjectStatus.DISCONNECTED, s.status)
        assertEquals("", s.preview)
    }

    @Test fun disconnected_on_tmux_error() {
        val s = AgentStatusDetector.detect("can't find session: dev", ProjectType.AGENT)
        assertEquals(ProjectStatus.DISCONNECTED, s.status)
    }

    @Test fun ssh_type_bypasses_heuristic_even_with_working_marker() {
        // SSH 项目永远 idle:即便屏上有 "esc to interrupt" 字样也不判 working
        val pane = """
            $ tail -f app.log
            press esc to interrupt the stream
            2026-05-28 listening on :8080
        """.trimIndent()
        val s = AgentStatusDetector.detect(pane, ProjectType.SSH)
        assertEquals(ProjectStatus.IDLE, s.status)
        assertEquals("2026-05-28 listening on :8080", s.preview)
    }

    @Test fun empty_pane_is_idle_no_preview() {
        val s = AgentStatusDetector.detect("\n   \n\t\n", ProjectType.CLAUDE)
        assertEquals(ProjectStatus.IDLE, s.status)
        assertEquals("", s.preview)
    }
}
