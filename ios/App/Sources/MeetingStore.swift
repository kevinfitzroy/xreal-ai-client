import Foundation

extension Notification.Name {
    /// 录音任务状态变化(新文件 / 转写中 / 完成 / 失败 / 投递)→ VC 据此刷 Home。
    static let meetingStoreDidChange = Notification.Name("meetingStoreDidChange")
}

/// 录音转写任务状态(对应 Home 列表展示)。`done` = 已成功投递到某 subproject(进「已处理」)。
enum RecordingState: String {
    case received     // 待处理:还没跑完转译/投递
    case processing   // 转译中 / 投递中(进行时,内存态,不持久)
    case done         // 已转译 + 已投递(进「已处理」,可折叠)
    case failed       // 某一步失败(留在「待处理」,带原因 + 重试)
}

/// 一个录音任务 = 收件箱里一个音频文件 + 它的 `.meta.json` 旁车状态。
struct RecordingTask {
    let audioURL: URL
    let name: String            // 去掉时间戳前缀 + 扩展名,给人看
    let receivedAt: Date
    let state: RecordingState
    let detail: String          // 子状态 / 失败原因,给 UI 副标题(如「待投递」「识别失败」「投递中」)
    let delivered: Bool         // 已投递成功(→ 已处理)
    let transcribed: Bool       // 已拿到逐字稿(可投递)
    let hasTarget: Bool         // 带自动投递目标(终端页录音);分享来的为 false
    let source: String          // recorded | shared
    let transcriptText: String? // 逐字稿(meta.transcript)
}

/// **持久化**的每条录音状态旁车(`<audio>.meta.json`)。落盘 → 崩溃/重启不丢:
/// 逐字稿(避免重试时重新 ASR)、失败步与原因、是否已投递、自动投递目标。
/// 「正在处理中」是瞬时态(内存 `processing` 集合),不写进来 —— 重启后回到 received 自然重跑。
struct RecordingMeta: Codable {
    var source: String = "shared"        // recorded | shared
    var transcript: String?              // markdown,ASR 成功后写;有它 = 已转译
    var failedStep: String?              // transcode | asr | deliver —— nil 表示没失败
    var error: String?                   // 失败原因(给人看)
    var delivered: Bool = false          // tmux 投递成功 → 进「已处理」
    var target: Target?                  // 自动投递目标(终端页录音带;分享来的为 nil,手动选)
    struct Target: Codable { var hostName: String; var session: String; var projectName: String }
}

/// 录音任务存储 + 处理。**全量持久化**(issue #23):所有录音落 App Group 收件箱,状态走 `.meta.json` 旁车,
/// 成功/失败只是分类不同、原始文件永不自动删。终端页录音与系统分享走**同一收件箱**;失败留在「待处理」可重试,
/// 投递成功移入「已处理」。处理走 `MeetingPipeline`(转码→豆包 ASR)+ `MeetingDelegate`(tmux 投递)。
final class MeetingStore {
    static let shared = MeetingStore()
    private init() {}

    private static let metaSuffix = ".meta.json"
    private static let legacyTranscriptSuffix = ".transcript.md"

    /// VC 注入:把 meta 里的 {hostName,session,projectName} 解析成可投递的 `MeetingDelegate.Target`
    /// (需当前 hosts + via)。host 被删 / 解析不出 → 返回 nil,投递记失败「找不到目标 host」。
    var resolveTarget: ((RecordingMeta.Target) -> MeetingDelegate.Target?)?

    private let lock = NSLock()
    private var processing: Set<String> = []    // 正在处理的文件名(瞬时,不持久)

    // MARK: - 读

    /// 当前所有任务,新→旧(旁车文件本身不算任务)。
    func tasks() -> [RecordingTask] {
        let audios = AudioInbox.pending().filter {
            let n = $0.lastPathComponent
            return !n.hasSuffix(Self.metaSuffix) && !n.hasSuffix(Self.legacyTranscriptSuffix)
        }
        lock.lock(); let proc = processing; lock.unlock()
        return audios.map { url in
            let meta = loadMeta(for: url)
            let received = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let inFlight = proc.contains(url.lastPathComponent)
            let (state, detail) = derive(meta: meta, inFlight: inFlight)
            return RecordingTask(
                audioURL: url, name: displayName(url), receivedAt: received,
                state: state, detail: detail, delivered: meta.delivered,
                transcribed: meta.transcript != nil, hasTarget: meta.target != nil,
                source: meta.source, transcriptText: meta.transcript)
        }
    }

    /// (state, 子状态文案)。delivered > 失败 > 进行中 > 待处理。
    private func derive(meta: RecordingMeta, inFlight: Bool) -> (RecordingState, String) {
        if meta.delivered { return (.done, "已投递") }
        if let step = meta.failedStep {
            switch step {
            case "transcode": return (.failed, "转码失败")
            case "asr":       return (.failed, "识别失败")
            case "deliver":   return (.failed, "投递失败")
            default:          return (.failed, "失败")
            }
        }
        if inFlight { return (.processing, meta.transcript != nil ? "投递中" : "转译中") }
        if meta.transcript != nil { return (.received, "待投递") }
        return (.received, "待转译")
    }

    /// 读完成/转译好的逐字稿文本(预览 / 委托用)。
    func transcript(for task: RecordingTask) -> String? {
        task.transcriptText ?? loadMeta(for: task.audioURL).transcript
    }

    // MARK: - 写入口

    /// 终端页录音落地:把录好的 WAV **拷进收件箱**(持久),写 meta 带自动投递目标,随即开始处理。
    /// 返回收件箱里的 URL。失败(App Group 不可用)抛错 —— 调用方需兜底提示,别让录音凭空消失。
    @discardableResult
    func ingestRecording(wav: URL, target: RecordingMeta.Target?, suggestedName: String = "录音") throws -> URL {
        let dst = try AudioInbox.ingest(copyingFrom: wav, suggestedName: suggestedName)
        var meta = RecordingMeta(); meta.source = "recorded"; meta.target = target   // nil → 仅转写,待手动投递
        saveMeta(meta, for: dst)
        process(dst)
        return dst
    }

    /// 处理所有未完成任务(幂等:done / 进行中跳过;failed 不自动重试,等用户点)。
    /// Home 出现 / app 前台 / 启动恢复时调 —— 崩溃后落盘文件据此自然续跑。
    func processPending() {
        for t in tasks() where t.state == .received {
            // 只跑真正有活的:没转译(要 ASR),或 已转译且有自动目标待投递(崩溃后续投)。
            // 已转译但无目标(分享来的待手动投递)= 无活,跳过,免每次刷 Home 空转闪烁。
            if !t.transcribed || t.hasTarget { process(t.audioURL) }
        }
    }

    /// 处理单个录音:按需 转码→ASR(已转译则跳过)→(有目标且未投递则)tmux 投递。
    /// 每步成功/失败都落 meta;失败留在原步、可重试。异步;状态变化发通知。
    func process(_ audioURL: URL) {
        let key = audioURL.lastPathComponent
        lock.lock()
        guard !processing.contains(key) else { lock.unlock(); return }
        processing.insert(key)
        lock.unlock()
        notify()
        Task {
            var meta = loadMeta(for: audioURL)
            // 1) 转译(没有逐字稿才跑)
            if meta.transcript == nil {
                do {
                    let t = try await MeetingPipeline.process(inboxFile: audioURL, enableSpeaker: true)
                    meta.transcript = t.asMarkdown(); meta.failedStep = nil; meta.error = nil
                    saveMeta(meta, for: audioURL)
                } catch {
                    meta.failedStep = "asr"; meta.error = humanError(error)
                    saveMeta(meta, for: audioURL)
                    AgentLog.error("meeting", "ASR failed \(key): \(error)")
                    finish(key); return
                }
            }
            // 2) 投递(有自动目标且尚未投递才跑;分享来的无目标 → 停在「待投递」,等手动委托)
            if let target = meta.target, !meta.delivered {
                if let resolved = resolveTarget?(target) {
                    switch await MeetingDelegate.deliver(transcript: meta.transcript ?? "", name: "录音", to: resolved) {
                    case .success:
                        meta.delivered = true; meta.failedStep = nil; meta.error = nil
                    case .failure(let e):
                        meta.failedStep = "deliver"; meta.error = humanError(e)
                        AgentLog.error("meeting", "deliver failed \(key): \(e)")
                    }
                } else {
                    meta.failedStep = "deliver"; meta.error = "找不到目标 host(可能已删除)"
                }
                saveMeta(meta, for: audioURL)
            }
            finish(key)
        }
    }

    /// 失败任务重试:清掉失败标记,从失败那步继续(转译失败→重转;投递失败→复用逐字稿重投)。
    func retry(_ task: RecordingTask) {
        var meta = loadMeta(for: task.audioURL)
        meta.failedStep = nil; meta.error = nil
        saveMeta(meta, for: task.audioURL)
        process(task.audioURL)
    }

    /// 手动把一条(已转译的)录音投递到指定 subproject —— 分享进来的录音在预览页选 subproject 后走这里。
    /// 成功 → 写 target + delivered,移入「已处理」。
    func markDelivered(_ task: RecordingTask, to target: RecordingMeta.Target) {
        var meta = loadMeta(for: task.audioURL)
        meta.target = target; meta.delivered = true; meta.failedStep = nil; meta.error = nil
        saveMeta(meta, for: task.audioURL)
        notify()
    }

    /// 删任务(音频 + meta + 旧旁车一起删)。
    func remove(_ task: RecordingTask) {
        AudioInbox.remove(task.audioURL)
        AudioInbox.remove(metaURL(for: task.audioURL))
        AudioInbox.remove(URL(fileURLWithPath: task.audioURL.path + Self.legacyTranscriptSuffix))
        lock.lock(); processing.remove(task.audioURL.lastPathComponent); lock.unlock()
        notify()
    }

    // MARK: - meta 旁车 I/O

    private func metaURL(for audio: URL) -> URL { URL(fileURLWithPath: audio.path + Self.metaSuffix) }

    private func loadMeta(for audio: URL) -> RecordingMeta {
        let url = metaURL(for: audio)
        if let data = try? Data(contentsOf: url),
           let meta = try? JSONDecoder().decode(RecordingMeta.self, from: data) {
            return meta
        }
        // 迁移:旧版只有 `.transcript.md`(= 已转译,未投递)→ 合成 meta 落盘一次。
        let legacy = URL(fileURLWithPath: audio.path + Self.legacyTranscriptSuffix)
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            var meta = RecordingMeta(); meta.source = "shared"; meta.transcript = text
            saveMeta(meta, for: audio)
            return meta
        }
        return RecordingMeta()
    }

    private func saveMeta(_ meta: RecordingMeta, for audio: URL) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL(for: audio), options: .atomic)
    }

    private func finish(_ key: String) {
        lock.lock(); processing.remove(key); lock.unlock()
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .meetingStoreDidChange, object: self) }
    }

    /// error → 短句(避免把 Swift 类型噪声塞满 UI)。
    private func humanError(_ error: Error) -> String {
        let s = "\(error)"
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
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
