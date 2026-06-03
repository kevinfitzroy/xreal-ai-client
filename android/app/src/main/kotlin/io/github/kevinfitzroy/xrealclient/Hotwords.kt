package io.github.kevinfitzroy.xrealclient

/**
 * 语音热词:提升 ASR 对开发/控制术语的识别准确率(豆包 `corpus.context` 内联热词)。
 *
 * 模型:**每个 project 一张表 = 继承的 [BASE] + 该 project 自己的词**(per-project 由 manifest
 * `projects[].hotwords` 带,现可能为空)。以后由 project 级「热词管理 skill」按识别错误自动扩充
 * (见 ROADMAP)。
 *
 * [BASE] 聚焦 **Claude Code 内部控制命令** —— 中文 ASR 最容易把这些英文短词听糊,统一在此兜底。
 */
object Hotwords {

    val BASE: List<String> = listOf(
        "Claude", "Claude Code",
        "compact", "context", "agent", "agents",
        "resume", "continue", "clear", "model",
        "review", "plan", "skill", "init", "memory",
        "commit", "ultrathink",
        // 会话/复用工具 + 常说的模型名(ASR 最易听错的专名:tmux→"提max",Opus/Sonnet/Haiku/DeepSeek)
        "tmux",
        "Opus", "Sonnet", "Haiku", "DeepSeek",
    )

    /**
     * **LLM 纠错专用大词表**(issue #16):不进 ASR(豆包 corpus 有 ~200 字预算上限),只喂给 LLM 纠错 prompt
     * —— LLM 能吃下大得多的词表,覆盖一大片 ASR 易错的英文技术专名。按领域分桶维护见 [HotwordDomains]。
     */
    val GLOSSARY: List<String> get() = HotwordDomains.all

    /** [BASE] + per-project,大小写不敏感去重(保留首次出现的原形)。**ASR 用**(随后 [cap] 截到预算)。 */
    fun merge(project: List<String>): List<String> = dedup(BASE + project)

    /** **LLM 纠错用**:在 ASR 热词([merge] 结果)之后追加 [GLOSSARY](项目词在前更显著),去重不截断。 */
    fun forCorrection(asrHotwords: List<String>): List<String> = dedup(asrHotwords + GLOSSARY)

    /**
     * 按字符数≈token 截断到预算。双向流式优化版内联热词上限 ~100 token,这里保守按 ~200 字符
     * (中文 1 字≈1 token,英文短词≈1-2 token;+1 算 JSON 包装开销)。
     */
    fun cap(words: List<String>, budget: Int = 200): List<String> {
        val out = ArrayList<String>()
        var used = 0
        for (w in words) {
            used += w.length + 1
            if (used > budget) break
            out.add(w)
        }
        return out
    }

    private fun dedup(words: List<String>): List<String> {
        val seen = HashSet<String>()
        return words.mapNotNull { raw ->
            val w = raw.trim()
            val key = w.lowercase()
            if (key.isEmpty() || !seen.add(key)) null else w
        }
    }
}
