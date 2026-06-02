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

    enum State { case idle, streaming, asrPending, preview }

    /// 注入文本到 SSH(VC 提供:转发到当前 SSHSession.send,单写者纪律由 SSHSession 保证)。
    /// nil = 当前无活动 PTY(列表态),注入 no-op。
    var inject: ((Data) -> Void)?
    /// 调 index.html overlay(VC 提供:eval window.showOverlay / hideOverlay)。
    private let showOverlayJS: (_ status: String, _ text: String) -> Void
    private let hideOverlayJS: () -> Void

    /// runtime swap:ASR 实现(有凭证 → VolcAsr,否则 MockAsr)。
    var asr: Asr
    /// 当前 project 的语音热词(进 project 时 VC 设;默认 = BASE)。
    var hotwords: [String] = Hotwords.base
    /// 注入时是否加 🎤 前缀。仅 AI-agent 类 project 开;裸 SSH **必须** false(前缀打进 bash 是废命令)。
    var voiceMarkerEnabled = false

    private var state: State = .idle
    private var currentText: String?
    private var inputWarning: String?
    private var stream: AsrStream?
    /// 会话代数:每次 down/esc ++,回调凭捕获的 gen 比对,过滤上一会话的迟到回调。
    private var asrGen = 0

    /// 录音 —— nil = 无麦克风权限(VC 在授权后注入)。
    var recorder: AudioCapture?

    init(asr: Asr,
         showOverlay: @escaping (_ status: String, _ text: String) -> Void,
         hideOverlay: @escaping () -> Void) {
        self.asr = asr
        self.showOverlayJS = showOverlay
        self.hideOverlayJS = hideOverlay
    }

    var currentState: State { state }
    var hasInputWarning: Bool { inputWarning != nil }

    func setInputWarning(_ warning: String?) {
        inputWarning = warning
        renderCurrentOverlay()
    }

    // MARK: - 语音键(SPA Bridge.voiceDown/voiceUp)

    func voiceDown(lang: String) {
        asrGen += 1
        let gen = asrGen
        stream?.cancel()
        recorder?.cancel()
        currentText = nil
        inputWarning = nil
        state = .streaming
        showOverlay("🎤 聆听中…", "")

        stream = asr.open(lang: lang, hotwords: hotwords, callback: GenCallback(gen: gen, owner: self))
        let recorderStarted = recorder?.start { [weak self] chunk in
            guard let self else { return }
            // 录音线程:仅当代数仍匹配才喂(重按后旧录音的尾块不进新会话)。
            if gen == self.asrGen { self.stream?.send(chunk) }
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
        recorder?.stop()             // 总是停采集(防 mic 卡死)
        guard state == .streaming else { return }
        stream?.finish()             // 发最后一包(负包),等最终结果
        state = .asrPending
        showOverlay("识别中…", currentText ?? "")
        AgentLog.debug("voice", "stream finish requested")
    }

    // MARK: - AsrCallback(经 GenCallback 带上 gen)

    fileprivate func onPartial(gen: Int, _ text: String) {
        guard gen == asrGen else { return }
        guard state == .streaming || state == .asrPending else { return }
        currentText = text
        let status = state == .streaming ? "🎤 聆听中…" : "识别中…"
        showOverlay(status, text)
    }

    fileprivate func onFinal(gen: Int, _ text: String) {
        guard gen == asrGen else { return }
        guard state == .streaming || state == .asrPending else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetIdle()
        } else {
            currentText = text
            state = .preview
            showOverlay("🎤 已识别", text)
        }
        NSLog("[VoiceController] FINAL chars=\(text.count)")   // 只打字数,不打内容
        AgentLog.info("voice", "final chars=\(text.count)")
    }

    fileprivate func onError(gen: Int, _ reason: String) {
        guard gen == asrGen else { return }
        NSLog("[VoiceController] ASR error: \(reason)")
        AgentLog.error("voice", "ASR error: \(reason.prefix(180))")
        showOverlayJS("⚠️ 语音中断", reason.isEmpty ? "请重试" : reason)
        // 留 2 秒让用户看到错误原因,然后自动收起 overlay。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.state != .idle else { return }
            self.state = .idle
            self.currentText = nil
            self.inputWarning = nil
            self.stream = nil
            self.hideOverlayJS()
        }
    }

    // AsrCallback 协议要求(不带 gen 的版本不会被直接调用 —— 都经 GenCallback)。
    func onPartial(_ text: String) {}
    func onFinal(_ text: String) {}
    func onError(_ reason: String) {}

    // MARK: - Enter 确认 / Esc 取消

    /// @return true = overlay 接管 Enter(写文本);false = 透传(正常 CR)。
    func onEnter() -> Bool {
        guard state == .preview else { return false }
        if inputWarning != nil {
            renderCurrentOverlay()
            AgentLog.warn("voice", "inject blocked by input warning")
            return true
        }
        guard let text = currentText else { resetIdle(); return false }
        let payload = voiceMarkerEnabled ? VoiceController.voiceMarker + text : text
        inject?(Data(payload.utf8))   // 不 auto-\n:语音误识安全网,再按 Enter 才执行
        AgentLog.info("voice", "inject preview chars=\(text.count) marker=\(voiceMarkerEnabled)")
        resetIdle()
        return true
    }

    /// @return true = 拦截(取消会话/preview);false = 透传。
    func onEsc() -> Bool {
        guard state != .idle else { return false }
        let passThrough = inputWarning != nil
        asrGen += 1                  // 作废当前会话的迟到回调
        stream?.cancel()
        recorder?.cancel()
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
        case .preview:
            showOverlay("🎤 已识别", currentText ?? "")
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
