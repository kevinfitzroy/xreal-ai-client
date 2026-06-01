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

    var onTapZone: ((TapZone) -> Void)?
    var onVoicePress: ((Bool) -> Void)?
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
        textLabel.textColor = UIColor(red: 0.58, green: 0.88, blue: 0.70, alpha: 1)   // #94e0b2
        textLabel.numberOfLines = 0

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = UIColor(white: 0.53, alpha: 1)
        hintLabel.text = "Enter 发送 · Esc 撤销"

        let stack = UIStackView(arrangedSubviews: [statusLabel, textLabel, hintLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

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

        let voicePress = UILongPressGestureRecognizer(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.minimumPressDuration = 0
        voicePress.cancelsTouchesInView = true
        voicePress.delegate = self
        addGestureRecognizer(voicePress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// 显示/更新浮层(主线程调用)。status 如 "🎤 聆听中…"/"识别中…"/"🎤 已识别";text = 当前识别文本。
    func show(status: String, text: String) {
        statusLabel.text = status
        textLabel.text = text
        textLabel.isHidden = text.isEmpty
        isHidden = false
        isUserInteractionEnabled = true
    }

    func hide() {
        isHidden = true
        isUserInteractionEnabled = false
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
