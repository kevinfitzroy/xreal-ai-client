import Foundation

/// 一句转写结果。`speaker` 是豆包返回的**数字 ID**("1"/"2"…),开了 `enable_speaker_info` 才有;
/// 没开或单声道场景为 nil。`startMs`/`endMs` 是该句在录音里的起止毫秒(用不上可忽略)。
struct MeetingUtterance {
    let text: String
    let speaker: String?
    let startMs: Int
    let endMs: Int
}

/// 一次录音的完整转写结果 = 插件产出的「资源」(后续委托给某个 subproject 的就是它的文本)。
/// **只听写、不理解** —— 带说话人标号的逐字稿,真正的整理在 subproject 里带项目上下文做。
struct MeetingTranscript {
    let utterances: [MeetingUtterance]
    /// 豆包给的整段文本(没有 utterances 切分时的兜底)。
    let fullText: String

    /// 是否含说话人信息(任一句带 speaker)。
    var hasSpeakers: Bool { utterances.contains { $0.speaker != nil } }

    /// 渲染成委托用的 Markdown:带说话人时合并连续同一人的句子成「说话人N: …」对话流;
    /// 无说话人时退化成纯段落。这是预览展示 + SFTP 丢给 subproject 的文本形态。
    func asMarkdown() -> String {
        guard hasSpeakers, !utterances.isEmpty else {
            return fullText.isEmpty ? utterances.map(\.text).joined(separator: "\n") : fullText
        }
        var lines: [String] = []
        var curSpeaker: String? = nil
        var buf: [String] = []
        func flush() {
            guard !buf.isEmpty else { return }
            let who = curSpeaker.map { "说话人\($0)" } ?? "未知"
            lines.append("**\(who)**:\(buf.joined(separator: ""))")
            buf.removeAll()
        }
        for u in utterances {
            if u.speaker != curSpeaker { flush(); curSpeaker = u.speaker }
            buf.append(u.text)
        }
        flush()
        return lines.joined(separator: "\n\n")
    }
}
