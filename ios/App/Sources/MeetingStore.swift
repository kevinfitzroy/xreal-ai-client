import Foundation

extension Notification.Name {
    /// 录音任务状态变化(新文件 / 转写中 / 完成 / 失败)→ VC 据此刷 Home。
    static let meetingStoreDidChange = Notification.Name("meetingStoreDidChange")
}

/// 录音转写任务状态(对应 Home 列表展示)。
enum RecordingState: String {
    case received     // 分享进收件箱,待处理
    case processing   // 转码 / 转录中
    case done         // 转写完成(有 .transcript.md 旁车)
    case failed       // 处理失败
}

/// 一个录音转写任务 = 收件箱里一个音频文件。
struct RecordingTask {
    let audioURL: URL
    let name: String            // 去掉时间戳前缀 + 扩展名,给人看
    let receivedAt: Date
    let state: RecordingState
    let transcriptURL: URL?     // done 时指向 .transcript.md
}

/// 录音转写任务存储 + 处理。**插件做"听写"的运行时**:任务来自 App Group 收件箱(Share Extension 落的),
/// 转写结果作为 `<audio>.transcript.md` 旁车持久化(存在即 `done`,跨重启不丢)。处理走 `MeetingPipeline`。
/// 状态变化发 `.meetingStoreDidChange`,Home 增量刷新。委托(SFTP 给 subproject)是下一步,这里只到"完成 + 文本就绪"。
final class MeetingStore {
    static let shared = MeetingStore()
    private init() {}

    private static let transcriptSuffix = ".transcript.md"

    private let lock = NSLock()
    private var processing: Set<String> = []    // 正在处理的文件名(audioURL.lastPathComponent)
    private var failed: [String: String] = [:]  // 文件名 → 失败原因

    /// 当前所有任务,新→旧。`.transcript.md` 旁车本身不算任务。
    func tasks() -> [RecordingTask] {
        let audios = AudioInbox.pending().filter { !$0.lastPathComponent.hasSuffix(Self.transcriptSuffix) }
        lock.lock(); let proc = processing; let fail = failed; lock.unlock()
        return audios.map { url in
            let sidecar = transcriptURL(for: url)
            let received = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let key = url.lastPathComponent
            let state: RecordingState =
                FileManager.default.fileExists(atPath: sidecar.path) ? .done
                : proc.contains(key) ? .processing
                : fail[key] != nil ? .failed
                : .received
            return RecordingTask(audioURL: url, name: displayName(url), receivedAt: received,
                                 state: state, transcriptURL: state == .done ? sidecar : nil)
        }
    }

    /// 处理所有 `received` 任务(幂等:done / processing 跳过)。Home 出现 / app 前台时调。
    func processPending() {
        for t in tasks() where t.state == .received { process(t.audioURL) }
    }

    /// 处理单个音频:转码 → 豆包识别 → 写旁车。异步;状态变化发通知。
    func process(_ audioURL: URL) {
        let key = audioURL.lastPathComponent
        lock.lock()
        guard !processing.contains(key) else { lock.unlock(); return }
        processing.insert(key); failed[key] = nil
        lock.unlock()
        notify()
        Task {
            do {
                let t = try await MeetingPipeline.process(inboxFile: audioURL, enableSpeaker: true)
                try t.asMarkdown().write(to: transcriptURL(for: audioURL), atomically: true, encoding: .utf8)
                lock.lock(); processing.remove(key); lock.unlock()
            } catch {
                lock.lock(); processing.remove(key); failed[key] = "\(error)"; lock.unlock()
                AgentLog.error("meeting", "store process failed \(key): \(error)")
            }
            notify()
        }
    }

    /// 读完成任务的逐字稿文本(预览 / 委托用)。
    func transcript(for task: RecordingTask) -> String? {
        guard let url = task.transcriptURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 删任务(音频 + 旁车一起删)。
    func remove(_ task: RecordingTask) {
        AudioInbox.remove(task.audioURL)
        AudioInbox.remove(transcriptURL(for: task.audioURL))
        lock.lock(); failed[task.audioURL.lastPathComponent] = nil; lock.unlock()
        notify()
    }

    // MARK: - helpers

    private func transcriptURL(for audio: URL) -> URL {
        URL(fileURLWithPath: audio.path + Self.transcriptSuffix)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .meetingStoreDidChange, object: self) }
    }

    /// 去掉 AudioInbox 加的 `yyyyMMdd-HHmmss-` 前缀 + 扩展名。
    private func displayName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let parts = base.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0].count == 8, parts[1].count == 6,
           parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) {
            return parts[2].isEmpty ? base : String(parts[2])
        }
        return base
    }
}
