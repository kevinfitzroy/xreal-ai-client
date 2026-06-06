import UIKit

/// 语音预览浮层(原生),替代 index.html 的 `#voice-overlay` div —— 终端改原生 SwiftTerm 后,overlay 也得原生。
/// 样式对齐 index.html:暗色圆角卡片,状态行 + 绿色识别文本 + 提示行;底部居中,不挡终端主体。
/// 由 `VoiceController` 经 `show(status:text:)` / `hide()` 驱动(状态机不变)。
final class VoiceOverlayView: UIView, UIGestureRecognizerDelegate {
    enum TapZone { case card, aboveCard }

    private let statusLabel = UILabel()
    private let textLabel = UILabel()
    private let hintLabel = UILabel()
    private let card = UIView()
    private var cardBottomConstraint: NSLayoutConstraint!

    // 上滑锁定录音态:计时 + 停止/取消按钮(录音时显示,平时隐藏)。
    private let recordingControls = UIStackView()
    private let stopButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var recTimer: Timer?
    private var recStart: Date?
    private weak var tapGR: UITapGestureRecognizer?
    private weak var voicePressGR: UILongPressGestureRecognizer?
    private static let cardBgNormal = UIColor(white: 0.08, alpha: 0.95)
    private static let cardBgArmed = UIColor(red: 0.22, green: 0.10, blue: 0.10, alpha: 0.96)
    /// 固定位置的「上滑到这里转录音」目标带 —— 位置不随 card 文字增长漂移,armed 判定精准。
    private let armHint = UILabel()

    // 纠错中(issue #16):状态行转圈动画 + 原文灰显 + 提示改"稍候"。spinner 由 overlay 自管,状态机不变。
    private var spinnerTimer: Timer?
    private var spinnerIndex = 0
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private let textColorNormal = UIColor(red: 0.58, green: 0.88, blue: 0.70, alpha: 1)   // #94e0b2
    private let textColorDimmed = UIColor(white: 0.5, alpha: 1)                            // 待替换 → 灰显
    private static let hintNormal = "Enter 发送 · Esc 撤销"
    private static let hintCorrecting = "稍候…别急着按 Enter"

    var onTapZone: ((TapZone) -> Void)?
    var onVoicePress: ((Bool) -> Void)?
    var onStopRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var reservedBottomInset: CGFloat = 0 {
        didSet { updateCardBottom() }
    }

    init() {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        // self 由 VC 设成 terminal 核心 frame(已排除 vkey);overlay 三段只在核心区内生效。

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        card.layer.cornerRadius = 12
        addSubview(card)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = UIColor(white: 0.9, alpha: 1)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 15)
        textLabel.textColor = textColorNormal
        textLabel.numberOfLines = 0

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = UIColor(white: 0.53, alpha: 1)
        hintLabel.text = Self.hintNormal

        let stack = UIStackView(arrangedSubviews: [statusLabel, textLabel, hintLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        stopButton.setTitle("停止并转写", for: .normal)
        stopButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        stopButton.tintColor = UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)
        stopButton.addTarget(self, action: #selector(stopTap), for: .touchUpInside)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        cancelButton.tintColor = UIColor(white: 0.7, alpha: 1)
        cancelButton.addTarget(self, action: #selector(cancelTap), for: .touchUpInside)
        recordingControls.axis = .horizontal
        recordingControls.distribution = .fillEqually
        recordingControls.spacing = 12
        recordingControls.addArrangedSubview(cancelButton)
        recordingControls.addArrangedSubview(stopButton)
        recordingControls.isHidden = true
        stack.addArrangedSubview(recordingControls)

        // 固定位置的 armed 目标带(centerY = 高度的 58%,不随 card 漂移)。
        armHint.text = "↑ 滑到这里 · 松手转录音"
        armHint.font = .systemFont(ofSize: 13, weight: .semibold)
        armHint.textColor = UIColor(white: 1, alpha: 0.92)
        armHint.textAlignment = .center
        armHint.backgroundColor = UIColor(white: 0, alpha: 0.5)
        armHint.layer.cornerRadius = 17
        armHint.clipsToBounds = true
        armHint.isHidden = true
        armHint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(armHint)
        NSLayoutConstraint.activate([
            armHint.centerXAnchor.constraint(equalTo: centerXAnchor),
            NSLayoutConstraint(item: armHint, attribute: .centerY, relatedBy: .equal,
                               toItem: self, attribute: .bottom, multiplier: 0.58, constant: 0),
            armHint.heightAnchor.constraint(equalToConstant: 34),
            armHint.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        cardBottomConstraint = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardBottomConstraint,
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        tapGR = tap

        let voicePress = UILongPressGestureRecognizer(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.minimumPressDuration = 0
        voicePress.cancelsTouchesInView = true
        voicePress.delegate = self
        addGestureRecognizer(voicePress)
        voicePressGR = voicePress
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// 显示/更新浮层(主线程调用)。status 如 "🎤 聆听中…"/"识别中…"/"🎤 已识别";text = 当前识别文本。
    /// 任何普通态都会**复位**纠错中样式(停 spinner、文本回绿、提示回默认)。
    func show(status: String, text: String) {
        stopSpinner()
        resetRecordingChrome()
        textLabel.textColor = textColorNormal
        hintLabel.isHidden = false
        hintLabel.text = Self.hintNormal
        statusLabel.text = status
        textLabel.text = text
        textLabel.isHidden = text.isEmpty
        // 流式态显示固定的 armed 目标带(供上滑锁定);其它态隐藏。
        armHint.text = "↑ 滑到这里 · 松手转录音"
        armHint.backgroundColor = UIColor(white: 0, alpha: 0.5)
        armHint.isHidden = !status.contains("聆听")
        isHidden = false
        isUserInteractionEnabled = true
    }

    /// 纠错中态(issue #16):状态行转圈("✨ AI 纠错中 ⠋")+ 原文灰显(待替换)+ 提示"稍候…别急着按 Enter"。
    /// 纠完由 [show] 复位回普通态。
    func showCorrecting(text: String) {
        textLabel.textColor = textColorDimmed
        hintLabel.text = Self.hintCorrecting
        textLabel.text = text
        textLabel.isHidden = text.isEmpty
        isHidden = false
        isUserInteractionEnabled = true
        startSpinner()
    }

    func hide() {
        stopSpinner()
        resetRecordingChrome()
        isHidden = true
        isUserInteractionEnabled = false
    }

    /// 复位录音/armed 视觉:停计时、隐按钮、卡片底色回常态、恢复 overlay 自身手势。
    private func resetRecordingChrome() {
        recTimer?.invalidate(); recTimer = nil
        recordingControls.isHidden = true
        card.backgroundColor = Self.cardBgNormal
        tapGR?.isEnabled = true
        voicePressGR?.isEnabled = true
        armHint.isHidden = true
    }

    /// armed 态(手指上滑到 overlay):提示「松手转录音」,保留当前识别文本。
    func showArmed(text: String) {
        stopSpinner()
        recTimer?.invalidate(); recTimer = nil
        recordingControls.isHidden = true
        tapGR?.isEnabled = true; voicePressGR?.isEnabled = true
        card.backgroundColor = Self.cardBgArmed
        textLabel.textColor = textColorNormal
        statusLabel.text = "↑ 松手转录音"
        textLabel.text = text
        textLabel.isHidden = text.isEmpty
        hintLabel.isHidden = false
        hintLabel.text = "滑回去 = 继续语音输入"
        armHint.text = "✓ 松手转录音"
        armHint.backgroundColor = UIColor(red: 0.85, green: 0.26, blue: 0.26, alpha: 0.95)
        armHint.isHidden = false
        isHidden = false
        isUserInteractionEnabled = true
    }

    /// 录音锁定态:计时 + 停止/取消按钮;停用 overlay 自身手势让按钮收触摸。
    func showRecording() {
        stopSpinner()
        card.backgroundColor = Self.cardBgNormal
        textLabel.isHidden = true
        hintLabel.isHidden = true
        recordingControls.isHidden = false
        armHint.isHidden = true
        tapGR?.isEnabled = false
        voicePressGR?.isEnabled = false
        isHidden = false
        isUserInteractionEnabled = true
        recStart = Date()
        updateRecLabel()
        recTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateRecLabel() }
        RunLoop.main.add(t, forMode: .common)
        recTimer = t
    }

    private func updateRecLabel() {
        let secs = max(0, Int(Date().timeIntervalSince(recStart ?? Date())))
        statusLabel.text = String(format: "🔴 录音中 · %02d:%02d", secs / 60, secs % 60)
    }

    /// armed 阈值:固定目标带的底边(overlay 坐标 ≈ terminal 核心坐标)。手指上滑过此线 = 进入 overlay 区域。
    /// 位置不随 card 文字增长漂移,判定稳定。
    func armZoneBottomY() -> CGFloat { armHint.frame.maxY }

    @objc private func stopTap() { onStopRecording?() }
    @objc private func cancelTap() { onCancelRecording?() }

    private func startSpinner() {
        stopSpinner()
        spinnerIndex = 0
        statusLabel.text = "✨ AI 纠错中 " + Self.spinnerFrames[0]
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinnerIndex = (self.spinnerIndex + 1) % Self.spinnerFrames.count
            self.statusLabel.text = "✨ AI 纠错中 " + Self.spinnerFrames[self.spinnerIndex]
        }
        RunLoop.main.add(t, forMode: .common)   // .common:滚动/手势跟踪时也持续转
        spinnerTimer = t
    }

    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    private func updateCardBottom() {
        guard cardBottomConstraint != nil else { return }
        cardBottomConstraint.constant = -max(24, reservedBottomInset + 12)
    }

    private func isBelowCard(_ p: CGPoint) -> Bool { p.y > card.frame.maxY }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if card.frame.contains(p) { onTapZone?(.card) }
        else if p.y < card.frame.minY { onTapZone?(.aboveCard) }
    }

    @objc private func handleVoicePress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            onVoicePress?(true)
        case .ended, .cancelled, .failed:
            onVoicePress?(false)
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let p = gestureRecognizer.location(in: self)
        if gestureRecognizer is UILongPressGestureRecognizer {
            return isBelowCard(p)
        }
        if gestureRecognizer is UITapGestureRecognizer {
            return !isBelowCard(p)
        }
        return true
    }
}
