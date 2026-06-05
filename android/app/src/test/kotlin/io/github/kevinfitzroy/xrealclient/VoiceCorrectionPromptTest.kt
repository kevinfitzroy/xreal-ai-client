package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [VoiceCorrectionPrompt] 纯函数:背景注入 + 段落按有无内容增删 + 原文必现 + 终端上下文截断。 */
class VoiceCorrectionPromptTest {

    private fun ctx(
        projectName: String = "Maestro",
        sessionType: String = "claude",
        isAiAgent: Boolean = true,
        hotwords: List<String> = listOf("kubectl", "Grafana"),
        lang: String = "zh",
        terminalTail: String? = null,
        recentCommands: List<String> = emptyList(),
    ) = VoiceContext(projectName, sessionType, isAiAgent, hotwords, lang, terminalTail, recentCommands)

    @Test fun `system prompt 强调只纠错 不改写 不揣摩意图 + 保守`() {
        val s = VoiceCorrectionPrompt.SYSTEM
        assertTrue(s.contains("纠错"))
        assertTrue(s.contains("绝不执行"))
        assertTrue(s.contains("不改写"))     // 只纠正不改写
        assertTrue(s.contains("揣摩"))       // 不揣摩意图
        assertTrue(s.contains("原样"))       // 保守:拿不准原样返回
        assertTrue(s.contains("自然语言"))   // 自然语言请求保持自然语言(别编成 git clone)
        assertTrue(s.contains("臆造"))       // 绝不臆造用户没说的 URL/路径/占位符
        assertTrue(s.contains("句式"))       // #22 句式铁律:句式/语气/人称/时态不许扭
        assertTrue(s.contains("人称"))       // #22 人称绝不反转(你↔我)
        assertTrue(s.contains("你可以"))     // #22 正反例:"你可以…"是描述,不许扭成"是否需要我…"
    }

    @Test fun `AI agent 会话才追加 Claude Code 内置命令例外`() {
        val ai = VoiceCorrectionPrompt.build("做一次上下文压缩", ctx(isAiAgent = true))
        assertTrue(ai.system.contains("/compact"))      // 例外在场
        assertTrue(ai.system.contains("内置命令"))
        val shell = VoiceCorrectionPrompt.build("做一次上下文压缩", ctx(isAiAgent = false, sessionType = "ssh"))
        assertFalse(shell.system.contains("/compact"))  // 裸 shell 不给例外(/compact 是废命令)
        assertFalse(shell.system.contains("内置命令"))
    }

    @Test fun `user 段含项目 语言 热词 且原文必现`() {
        val m = VoiceCorrectionPrompt.build("帮我看下 cubectl 的状态", ctx())
        assertTrue(m.user.contains("[项目] Maestro"))
        assertTrue(m.user.contains("claude"))
        assertTrue(m.user.contains("AI agent"))
        assertTrue(m.user.contains("[语言] 中文"))
        assertTrue(m.user.contains("[热词] kubectl、Grafana"))
        assertTrue(m.user.contains("[待纠正的 ASR 原文]"))
        assertTrue(m.user.contains("帮我看下 cubectl 的状态"))   // 原文一字不漏带进去
    }

    @Test fun `en 语言标注英文 且裸 shell 标注`() {
        val m = VoiceCorrectionPrompt.build("pwd", ctx(lang = "en", isAiAgent = false, sessionType = "ssh"))
        assertTrue(m.user.contains("[语言] 英文"))
        assertTrue(m.user.contains("裸 shell"))
    }

    @Test fun `空热词 空终端 空历史 时对应段落不出现`() {
        val m = VoiceCorrectionPrompt.build("ls", ctx(hotwords = emptyList()))
        assertFalse(m.user.contains("[热词]"))
        assertFalse(m.user.contains("[终端最近输出]"))
        assertFalse(m.user.contains("[最近语音指令]"))
    }

    @Test fun `有终端上下文和历史时段落出现`() {
        val m = VoiceCorrectionPrompt.build(
            "git status",
            ctx(terminalTail = "evan@host:~/work$ ls\nREADME.md", recentCommands = listOf("cd work", "ls -la")),
        )
        assertTrue(m.user.contains("[终端最近输出]"))
        assertTrue(m.user.contains("README.md"))
        assertTrue(m.user.contains("[最近语音指令]"))
        assertTrue(m.user.contains("- cd work"))
        assertTrue(m.user.contains("- ls -la"))
    }

    @Test fun `终端上下文超预算时截尾保留最近内容`() {
        val long = (1..5000).joinToString("") { "x" } + "TAIL_MARKER"
        val m = VoiceCorrectionPrompt.build("ls", ctx(terminalTail = long))
        assertTrue(m.user.contains("TAIL_MARKER"))   // 保留末尾(最近)
        // 截断到预算内:终端块不应包含全部 5000+ 字符
        assertTrue(m.user.length < 5000)
    }
}
