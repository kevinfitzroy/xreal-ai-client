import Foundation

/// 语音输入状态机(真流式)—— Android `VoiceDaemon.kt` 的 port。按住说话,边录边传,识别结果实时上屏。
///
///   voiceDown → 开 ASR 会话(连 WS)+ 开录音,PCM chunk 实时喂入 → state STREAMING
///   识别中间结果 → onPartial → 实时刷 overlay(全量文本替换)
///   voiceUp   → 停录 + 发最后一包(负包) → state ASR_PENDING
///   onFinal   → state PREVIEW(等用户确认)
///   Enter     → 把文本写 SSH → IDLE(不 auto-\n:语音误识安全网,再按 Enter 才执行)
///   Esc / 重按 → 取消会话 → IDLE
///
/// **late-callback race**:重按/取消后旧 WS reader 可能还喷 partial。两层防御 ——
/// generation counter(`asrGen`)+ VolcAsr 内部 cancelled flag。
///
/// 与 Android 不同点:iOS 物理键本期未接,语音键经 index.html 的 `Bridge.voiceDown/voiceUp`
/// 触发(SPA 语音键)。所有方法在主线程调用(bridge 回调 + UI eval 都在 main)。
final class VoiceController: AsrCallback {

    enum State { case idle, streaming, asrPending, correcting, preview, recording }

    /// 注入文本到 SSH(VC 提供:转发到当前 SSHSession.send,单写者纪律由 SSHSession 保证)。
    /// nil = 当前无活动 PTY(列表态),注入 no-op。
    var inject: ((Data) -> Void)?
    /// 调 overlay(VC 提供)。普通态 showOverlay;纠错态 showCorrecting(自带 spinner 动画);收起 hideOverlay。
    private let showOverlayJS: (_ status: String, _ text: String) -> Void
    private let showCorrectingJS: (_ text: String) -> Void
    private let hideOverlayJS: () -> Void

    /// runtime swap:ASR 实现(有凭证 → VolcAsr,否则 MockAsr)。
    var asr: Asr
    /// 当前 project 的语音热词(进 project 时 VC 设;默认 = BASE)。
    var hotwords: [String] = Hotwords.base
    /// 注入时是否加 🎤 前缀。仅 AI-agent 类 project 开;裸 SSH **必须** false(前缀打进 bash 是废命令)。
    var voiceMarkerEnabled = false

    // ── LLM 上下文纠错(issue #16)。corrector==nil → 纠错关闭,行为同改造前 ──────────────────
    /// 纠错引擎(未配置 = nil → 跳过纠错直接 preview)。VC 启动按 CorrectionConfig 注入。
    var corrector: VoiceCorrector?
    /// 终端背景来源(tmux capture-pane,async)。VC 在连上真 SSH 时注入;无连接/列表态 = nil。
    var terminalContext: (() async -> String?)?
    /// 当前 project 显示名 / session 类型,喂给纠错 prompt(applyVoiceContext 设)。
    var projectName = ""
    var sessionType = "ssh"
    /// 上滑 armed 锁定中:VC 占屏显示 armed(红带),流式 ASR partial 不要覆盖 overlay(仍更新 currentText)。
    var armedLock = false

    private var state: State = .idle
    private var currentText: String?
    private var inputWarning: String?
    private var stream: AsrStream?
    /// 当前会话语种(voiceDown 设),纠错 prompt 用(提示别跨语种乱译)。
    private var lang = "zh"
    /// 最近已确认注入的语音指令(最新在 first,上限 RECENT_MAX),给纠错 prompt 连续指令上下文。
    private var recentCommands: [String] = []
    /// 会话代数:每次 down/esc ++,回调凭捕获的 gen 比对,过滤上一会话的迟到回调。
    private var asrGen = 0
    private static let recentMax = 5

    /// 录音 —— nil = 无麦克风权限(VC 在授权后注入)。
    var recorder: AudioCapture?
    /// 上滑锁定录音时,PCM 边采边 tee 到这份 WAV(2A 无缝);正常松手则丢弃。
    private var wavWriter: PcmWavWriter?

    init(asr: Asr,
         showOverlay: @escaping (_ status: String, _ text: String) -> Void,
         showCorrecting: @escaping (_ text: String) -> Void,
         hideOverlay: @escaping () -> Void) {
        self.asr = asr
        self.showOverlayJS = showOverlay
        self.showCorrectingJS = showCorrecting
        self.hideOverlayJS = hideOverlay
    }

    var currentState: State { state }
    var currentPartial: String? { currentText }
    var hasInputWarning: Bool { inputWarning != nil }

    /// 上滑 armed 后又滑回 → 恢复流式 overlay 显示。
    func reshowStreaming() {
        guard state == .streaming else { return }
        showOverlay("🎤 聆听中…", currentText ?? "")
    }

    func setInputWarning(_ warning: String?) {
        inputWarning = warning
        renderCurrentOverlay()
    }

    // MARK: - 语音键(SPA Bridge.voiceDown/voiceUp)

    func voiceDown(lang: String) {
        self.lang = lang
        asrGen += 1
        let gen = asrGen
        stream?.cancel()
        recorder?.cancel()
        wavWriter?.discard(); wavWriter = nil      // 清上一会话的 tee 残留
        armedLock = false
        currentText = nil
        inputWarning = nil
        state = .streaming
        showOverlay("🎤 聆听中…", "")

        // tee 一份 WAV(2A 无缝):音频从按下就写;上滑锁定即得完整录音,正常松手则丢弃。
        wavWriter = PcmWavWriter(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).wav"))

        stream = asr.open(lang: lang, hotwords: hotwords, callback: GenCallback(gen: gen, owner: self))
        let recorderStarted = recorder?.start { [weak self] chunk in
            guard let self else { return }
            self.wavWriter?.append(chunk)                                  // 无条件 tee 到 WAV
            if gen == self.asrGen, self.state == .streaming { self.stream?.send(chunk) }   // 仅流式喂 ASR
        } ?? false
        guard recorderStarted else {
            stream?.cancel()
            showOverlayJS("⚠️ 麦克风启动失败", "请检查麦克风权限后重试")
            NSLog("[VoiceController] recorder start failed")
            AgentLog.error("voice", "recorder start failed")
            resetIdle()
            return
        }
        NSLog("[VoiceController] STREAMING start lang=\(lang) recorder=\(recorder != nil) hotwords=\(hotwords.count)")
        AgentLog.info("voice", "stream start lang=\(lang) recorder=\(recorder != nil) hotwords=\(hotwords.count)")
    }

    func voiceUp(lang: String) {
        guard state != .recording else { return }   // 录音锁定态不受松手影响(由 overlay 停止键结束)
        recorder?.stop()             // 总是停采集(防 mic 卡死)
        wavWriter?.discard(); wavWriter = nil        // 正常语音路径不要这份 tee
        guard state == .streaming else { return }
        stream?.finish()             // 发最后一包(负包),等最终结果
        state = .asrPending
        showOverlay("识别中…", currentText ?? "")
        AgentLog.debug("voice", "stream finish requested")
    }

    // MARK: - 上滑锁定 → 录音态(长录音 → 转写 → 委托当前 subproject)

    /// 松手时手指在 overlay 上 → 锁进录音态:停喂 ASR(作废会话),保持采集 + 继续 tee 到 WAV。
    /// overlay 的录音 UI(计时/停止/取消)由 VC 驱动。
    func lockToRecording() {
        guard state == .streaming else { return }
        asrGen += 1               // 作废 ASR 会话(停喂 + 丢迟到回调)
        stream?.cancel(); stream = nil
        currentText = nil; inputWarning = nil
        state = .recording        // 采集与 wavWriter 继续(onChunk 仍在 tee)
        AgentLog.info("voice", "locked to recording")
    }

    /// 停止录音,返回完整 WAV(nil = 没在录/空)。VC 据此跑转写 + 委托。
    @discardableResult
    func stopRecording() -> URL? {
        guard state == .recording else { return nil }
        recorder?.stop()          // flush 尾块到 wavWriter
        let url = wavWriter?.finalize()
        wavWriter = nil
        state = .idle
        AgentLog.info("voice", "stop recording → \(url?.lastPathComponent ?? "nil")")
        return url
    }

    /// 取消录音,丢弃 WAV。
    func cancelRecording() {
        guard state == .recording else { return }
        recorder?.cancel()
        wavWriter?.discard(); wavWriter = nil
        state = .idle
        AgentLog.info("voice", "cancel recording")
    }

    // MARK: - AsrCallback(经 GenCallback 带上 gen)

    fileprivate func onPartial(gen: Int, _ text: String) {
        guard gen == asrGen else { return }
        guard state == .streaming || state == .asrPending else { return }
        currentText = text
        if armedLock { return }   // armed 中由 VC 占屏(红带),别让流式 partial 把 overlay 重置回"聆听中"
        let status = state == .streaming ? "🎤 聆听中…" : "识别中…"
        showOverlay(status, text)
    }

    fileprivate func onFinal(gen: Int, _ text: String) {
        guard gen == asrGen else { return }
        guard state == .streaming || state == .asrPending else { return }
        NSLog("[VoiceController] FINAL chars=\(text.count)")   // 只打字数,不打内容
        AgentLog.info("voice", "final chars=\(text.count)")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { resetIdle(); return }
        currentText = text

        guard let corrector = self.corrector else {   // 纠错关闭:直接预览(改造前行为)
            state = .preview
            showOverlay("🎤 已识别", text)
            return
        }

        // 纠错开启:进 correcting,后台抓 tmux 上下文 + 跑 LLM,完成回 preview(失败回退原文)。
        // gen 守卫:期间用户重按/Esc 会 ++asrGen,迟到的纠错结果被丢弃。
        state = .correcting
        showCorrectingJS(text)   // 转圈动画 + 原文灰显 + "稍候"提示(overlay 自管 spinner)
        // 在 main 先把上下文快照成不可变值(Task 内不碰 self,只在末尾 hop 回 main 用 gen 守卫)。
        let ctxSource = terminalContext
        let snapshot = VoiceContext(
            projectName: projectName, sessionType: sessionType, isAiAgent: voiceMarkerEnabled,
            hotwords: Hotwords.forCorrection(hotwords),   // ASR 热词 + LLM 大词表;ASR 路径仍用小表
            lang: lang, terminalTail: nil, recentCommands: recentCommands
        )
        Task { [weak self] in
            let tail = await ctxSource?()
            var ctx = snapshot
            if let tail, !tail.isEmpty {
                ctx = VoiceContext(projectName: snapshot.projectName, sessionType: snapshot.sessionType,
                                   isAiAgent: snapshot.isAiAgent, hotwords: snapshot.hotwords,
                                   lang: snapshot.lang, terminalTail: tail, recentCommands: snapshot.recentCommands)
            }
            let corrected = await corrector.correct(text, ctx: ctx)
            await MainActor.run {
                guard let self, gen == self.asrGen, self.state == .correcting else { return }   // 已取消/被新会话取代
                self.currentText = corrected
                self.state = .preview
                self.showOverlay(corrected != text ? "✨ 已纠错" : "🎤 已识别", corrected)
            }
        }
    }

    /// 预热纠错连接(进 project 时 VC 调):后台建好到 LLM 的连接,首次纠错不付握手。
    func prewarmCorrector() {
        guard let corrector = self.corrector else { return }
        Task { await corrector.prewarm() }
    }

    fileprivate func onError(gen: Int, _ reason: String) {
        guard gen == asrGen else { return }
        NSLog("[VoiceController] ASR error: \(reason)")
        AgentLog.error("voice", "ASR error: \(reason.prefix(180))")
        showOverlayJS("⚠️ 语音中断", reason.isEmpty ? "请重试" : reason)
        // 留 2 秒让用户看到错误原因,然后自动收起 overlay。
        // gen 守卫:期间用户若又按了说话(asrGen 自增),别清掉新会话。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, gen == self.asrGen else { return }
            self.resetIdle()
        }
    }

    // AsrCallback 协议要求(不带 gen 的版本不会被直接调用 —— 都经 GenCallback)。
    func onPartial(_ text: String) {}
    func onFinal(_ text: String) {}
    func onError(_ reason: String) {}

    // MARK: - Enter 确认 / Esc 取消

    /// @return true = overlay 接管 Enter(写文本);false = 透传(正常 CR)。
    func onEnter() -> Bool {
        // 纠错进行中按 Enter:拦截但不动作(别让这个 CR 漏进 shell);等纠错完成进 preview 再按。
        if state == .correcting { return true }
        guard state == .preview else { return false }
        if inputWarning != nil {
            renderCurrentOverlay()
            AgentLog.warn("voice", "inject blocked by input warning")
            return true
        }
        guard let text = currentText else { resetIdle(); return false }
        // 首字符是 ! / 时不加 🎤:! = 直接执行 bash,/ = Claude Code 内置命令;加了前缀这俩都会被当成普通文本而非命令。
        let isCommand = text.first == "!" || text.first == "/"
        let payload = (voiceMarkerEnabled && !isCommand) ? VoiceController.voiceMarker + text : text
        inject?(Data(payload.utf8))   // 不 auto-\n:语音误识安全网,再按 Enter 才执行
        recordRecent(text)            // 进纠错 prompt 的"最近指令"上下文
        AgentLog.info("voice", "inject preview chars=\(text.count) marker=\(voiceMarkerEnabled)")
        resetIdle()
        return true
    }

    private func recordRecent(_ text: String) {
        recentCommands.insert(text, at: 0)
        if recentCommands.count > Self.recentMax { recentCommands.removeLast(recentCommands.count - Self.recentMax) }
    }

    /// @return true = 拦截(取消会话/preview);false = 透传。
    func onEsc() -> Bool {
        guard state != .idle else { return false }
        let passThrough = inputWarning != nil
        asrGen += 1                  // 作废当前会话的迟到回调
        stream?.cancel()
        recorder?.cancel()
        wavWriter?.discard(); wavWriter = nil
        resetIdle()
        NSLog("[VoiceController] ESC cancel")
        AgentLog.info("voice", "cancel")
        return !passThrough
    }

    /// 切 project / 回列表 / 断连时收尾(不重建 VoiceController)。
    func shutdown() {
        asrGen += 1
        stream?.cancel()
        recorder?.cancel()
        wavWriter?.discard(); wavWriter = nil
        hideOverlay()
        state = .idle
        currentText = nil
        inputWarning = nil
        stream = nil
        AgentLog.debug("voice", "shutdown")
    }

    private func resetIdle() {
        state = .idle
        currentText = nil
        inputWarning = nil
        stream = nil
        wavWriter?.discard(); wavWriter = nil
        hideOverlay()
    }

    private func renderCurrentOverlay() {
        switch state {
        case .idle:
            return
        case .streaming:
            showOverlay("🎤 聆听中…", currentText ?? "")
        case .asrPending:
            showOverlay("识别中…", currentText ?? "")
        case .correcting:
            showCorrectingJS(currentText ?? "")
        case .preview:
            showOverlay("🎤 已识别", currentText ?? "")
        case .recording:
            return   // 录音态 overlay 由 VC 驱动(计时/停止/取消)
        }
    }

    private func showOverlay(_ status: String, _ text: String) {
        if let inputWarning {
            let body = text.isEmpty ? inputWarning : "\(inputWarning)\n\n\(text)"
            showOverlayJS("⚠️ 先按 Esc 退出翻页模式", body)
        } else {
            showOverlayJS(status, text)
        }
    }
    private func hideOverlay() { hideOverlayJS() }

    /// 注入 AI-agent 会话时的语音前缀(U+1F3A4 + 空格)。与 sub-project CLAUDE.md 约定一致。
    static let voiceMarker = "🎤 "
}

/// 把 ASR 回调带上捕获的 `gen` 转发给 VoiceController(回调来自 WS/定时器线程 → hop 到 main)。
private final class GenCallback: AsrCallback {
    let gen: Int
    weak var owner: VoiceController?
    init(gen: Int, owner: VoiceController) { self.gen = gen; self.owner = owner }
    func onPartial(_ text: String) { DispatchQueue.main.async { self.owner?.onPartial(gen: self.gen, text) } }
    func onFinal(_ text: String)   { DispatchQueue.main.async { self.owner?.onFinal(gen: self.gen, text) } }
    func onError(_ reason: String) { DispatchQueue.main.async { self.owner?.onError(gen: self.gen, reason) } }
}
