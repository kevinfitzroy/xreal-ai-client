import Foundation

/// 语音热词:提升 ASR 对开发/控制术语的识别准确率(豆包 `corpus.context` 内联热词)。
/// Android `Hotwords.kt` 的 port。
///
/// 模型:**每个 project 一张表 = 继承的 BASE + 该 project 自己的词**(per-project 由 manifest
/// `projects[].hotwords` 带)。BASE 聚焦 Claude Code 内部控制命令 —— 中文 ASR 最易把这些英文短词听糊。
enum Hotwords {

    static let base: [String] = [
        "Claude", "Claude Code",
        "compact", "context", "agent", "agents",
        "resume", "continue", "clear", "model",
        "review", "plan", "skill", "init", "memory",
        "commit", "ultrathink",
    ]

    /// BASE + per-project,大小写不敏感去重(保留首次出现的原形)。
    static func merge(_ project: [String]) -> [String] { dedup(base + project) }

    /// 按字符数≈token 截断到预算(~200 字符;中文 1 字≈1 token,英文短词≈1-2;+1 算 JSON 包装开销)。
    static func cap(_ words: [String], budget: Int = 200) -> [String] {
        var out: [String] = []
        var used = 0
        for w in words {
            used += w.count + 1
            if used > budget { break }
            out.append(w)
        }
        return out
    }

    private static func dedup(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in words {
            let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = w.lowercased()
            if key.isEmpty || !seen.insert(key).inserted { continue }
            out.append(w)
        }
        return out
    }
}
