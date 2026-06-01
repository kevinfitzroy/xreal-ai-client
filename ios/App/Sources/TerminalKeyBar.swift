import UIKit

/// 触屏虚拟键盘的动作。文本输入靠语音(本产品语音优先),故 key bar 只放特殊键。
enum TerminalKeyAction {
    case back, up, down, left, right, enter, esc, tab, shiftTab, ctrlC, delWord, voiceDown, voiceUp
}

/// 触屏虚拟键盘(原生),**无硬件键盘时**挂为 SwiftTerm 的 `inputAccessoryView`。视觉对齐 index.html 的
/// `.kc` 风格(大符号 + 小副标题、暗色圆角)。一行:返回 / ←↑↓→ / Enter / Esc / 删词 / Tab / 模式 / Ctrl-C / 🎤。
/// 🎤 hold-to-talk(touchDown=voiceDown、抬起=voiceUp);其余 tap。动作回调给 VC 统一处理。
///
/// **inputAccessoryView 高度坑**:内容必须锚到 `safeAreaLayoutGuide`(否则被 home indicator 压住裁掉),
/// 且 `intrinsicContentSize` 要把底部安全区算进去,否则要么裁要么挤。安全区变化时 invalidate。
final class TerminalKeyBar: UIInputView {
    var onAction: ((TerminalKeyAction) -> Void)?

    private static let contentHeight: CGFloat = 50

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.contentHeight + safeAreaInsets.bottom)
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }

    // (符号, 副标题, 动作)。voice 单列(需按下/抬起)。
    private static let keys: [(String, String, TerminalKeyAction)] = [
        ("⌂", "返回", .back),
        ("←", "", .left), ("↑", "", .up), ("↓", "", .down), ("→", "", .right),
        ("↵", "Enter", .enter), ("⎋", "Esc", .esc), ("⌫", "删词", .delWord),
        ("⇥", "Tab", .tab), ("⇧⇥", "模式", .shiftTab), ("^C", "中断", .ctrlC),
    ]

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.contentHeight), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleHeight
        allowsSelfSizing = true

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 5
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // 锚 safeAreaLayoutGuide → 内容始终在 home indicator 之上
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])

        for (sym, sub, action) in Self.keys {
            stack.addArrangedSubview(makeButton(symbol: sym, sub: sub, tap: action))
        }
        stack.addArrangedSubview(makeVoiceButton())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func makeButton(symbol: String, sub: String, tap action: TerminalKeyAction) -> UIButton {
        let b = styledButton(symbol: symbol, sub: sub)
        b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        return b
    }

    private func makeVoiceButton() -> UIButton {
        let b = styledButton(symbol: "🎤", sub: "语音")
        b.addAction(UIAction { [weak self] _ in self?.onAction?(.voiceDown) }, for: .touchDown)
        let up = UIAction { [weak self] _ in self?.onAction?(.voiceUp) }
        b.addAction(up, for: .touchUpInside)
        b.addAction(up, for: .touchUpOutside)
        b.addAction(up, for: .touchCancel)
        return b
    }

    /// index.html `.kc` 风格:大符号(kl)+ 小副标题(ks,暗、大写)。用 Configuration 的 title/subtitle 两级。
    private func styledButton(symbol: String, sub: String) -> UIButton {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.plain()
        cfg.background.backgroundColor = UIColor(white: 1, alpha: 0.12)
        cfg.background.cornerRadius = 7
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)

        var title = AttributedString(symbol)
        title.font = .systemFont(ofSize: symbol.count > 1 ? 14 : 19, weight: .bold)
        cfg.attributedTitle = title

        if !sub.isEmpty {
            var subt = AttributedString(sub)
            subt.font = .systemFont(ofSize: 8, weight: .regular)
            cfg.attributedSubtitle = subt
            cfg.titleAlignment = .center
            cfg.titlePadding = 1
        }
        b.configuration = cfg
        b.tintColor = UIColor(white: 0.92, alpha: 1)
        return b
    }
}
