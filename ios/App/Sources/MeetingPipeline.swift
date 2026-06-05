import Foundation

/// 一个录音任务在插件里的状态机(对应 Home 列表的状态展示)。`done` 携带产出资源。
enum MeetingTaskState {
    case received       // 分享进收件箱,待处理
    case transcoding    // m4a → 16k WAV
    case transcribing   // 豆包录音文件识别
    case done(MeetingTranscript)
    case failed(String)
}

/// 听写流水线:收件箱里一个音频文件 → 转码 → 豆包录音文件识别 → 逐字稿资源。
/// **纯插件闭环**,不接委托、不碰 Home UI;状态通过 `onState` 回吐(以后 Home 列表订阅它驱动展示)。
enum MeetingPipeline {

    /// 处理单个收件箱文件。`enableSpeaker` 小范围会议建议开。返回逐字稿;失败抛错。
    /// 转码是同步 CPU 活,挪到后台;识别是异步网络。`onState` 在调用线程外触发,UI 自行 marshal。
    @discardableResult
    static func process(inboxFile: URL,
                        enableSpeaker: Bool = true,
                        onState: ((MeetingTaskState) -> Void)? = nil) async throws -> MeetingTranscript {
        onState?(.transcoding)
        let segDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xreal-meeting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: segDir) }

        do {
            // 分段转码:短录音 1 段,长录音(>10min)多段,每段 ≤10min 独立上传、可逐段重试(issue #19)。
            let segments = try await Task.detached(priority: .userInitiated) {
                try AudioTranscoder.toWav16kMonoSegments(input: inboxFile, outputDir: segDir)
            }.value
            AgentLog.info("meeting", "transcoded \(inboxFile.lastPathComponent) → \(segments.count) 段 WAV")

            onState?(.transcribing)
            let transcript = try await VolcFileAsr.recognizeSegments(segments, enableSpeaker: enableSpeaker)
            onState?(.done(transcript))
            return transcript
        } catch {
            AgentLog.error("meeting", "pipeline failed for \(inboxFile.lastPathComponent): \(error)")
            onState?(.failed("\(error)"))
            throw error
        }
    }
}
