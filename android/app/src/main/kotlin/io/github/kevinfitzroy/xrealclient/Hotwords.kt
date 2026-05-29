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
    )

    /** [BASE] + per-project,大小写不敏感去重(保留首次出现的原形)。 */
    fun merge(project: List<String>): List<String> = dedup(BASE + project)

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
