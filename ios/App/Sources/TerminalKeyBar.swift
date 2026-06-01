import UIKit

/// 触屏虚拟键盘的动作。文本输入靠语音(本产品语音优先),故 key bar 只放特殊键。
enum TerminalKeyAction {
    case back, up, down, left, right, enter, esc, tab, shiftTab, ctrlC, ctrlB, delWord, voiceDown, voiceUp
}

/// 触屏虚拟键盘(原生),**无硬件键盘时**挂为 SwiftTerm 的 `inputAccessoryView`。视觉对齐 index.html `.kc`
/// (大符号 + 小副标题、暗色圆角)。键:返回/←↑↓→/Enter/Esc/删词/Tab/模式/Ctrl-C/🎤语音。
/// 🎤 hold-to-talk;其余 tap。动作回调给 VC。
///
/// **响应式行数(SPEC §6.1)**:横屏 1 行、竖屏 2 行 —— 按自身宽度(=屏宽)判,>500 视为横屏。
/// **inputAccessoryView 高度坑**:`intrinsicContentSize` 要含底部安全区,内容锚 `safeAreaLayoutGuide`,
/// 否则被 home indicator 压住裁掉;行数变化 invalidate 高度(→ 键盘 frame 变 → VC 重排终端避让)。
final class TerminalKeyBar: UIInputView {
    var onAction: ((TerminalKeyAction) -> Void)?

    private static let rowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 5
    private static let vInset: CGFloat = 5

    private let container = UIStackView()   // 竖直容器,放 1~2 个横排
    private var containerHeightC: NSLayoutConstraint!   // 显式高度,防 fillEqually + 自适应循环把 keybar 撑满屏
    private var keyButtons: [UIButton] = []
    private var voiceButton: UIButton!
    private var currentRows = 0

    // (符号, 副标题, 动作);voice 单列(需按下/抬起)。竖屏 2 行时前 6 / 后 6 拆分。
    private static let keys: [(String, String, TerminalKeyAction)] = [
        ("⌂", "返回", .back),
        ("←", "", .left), ("↑", "", .up), ("↓", "", .down), ("→", "", .right),
        ("↵", "Enter", .enter), ("⎋", "Esc", .esc), ("⌫", "删词", .delWord),
        ("^B", "Ctrl-B", .ctrlB), ("⇧⇥", "模式", .shiftTab), ("^C", "中断", .ctrlC),
    ]

    override var intrinsicContentSize: CGSize {
        let rows = max(currentRows, 1)
        let h = CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowSpacing + Self.vInset * 2
        return CGSize(width: UIView.noIntrinsicMetric, height: h + safeAreaInsets.bottom)
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.rowHeight), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]   // flexibleHeight 必需:否则键盘系统用 frame 高度(忽略 intrinsicContentSize)
        allowsSelfSizing = true
        overrideUserInterfaceStyle = .dark   // 终端永远暗

        // 不透明深色背景盖住系统键盘的浅色底(overrideUserInterfaceStyle 对 .keyboard 的 blur 底不生效)。
        let bg = UIView()
        bg.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        container.axis = .vertical
        container.spacing = Self.rowSpacing
        container.distribution = .fillEqually
        container.alignment = .fill
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        // 显式高度:避免 fillEqually 竖直容器与 keybar 自适应高度循环依赖(会撑满屏 / 叠成一行)。
        containerHeightC = container.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 5),
            container.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -5),
            container.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: Self.vInset),
            containerHeightC,
        ])

        for (sym, sub, action) in Self.keys {
            keyButtons.append(makeButton(symbol: sym, sub: sub, tap: action))
        }
        voiceButton = makeVoiceButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private var allButtons: [UIButton] { keyButtons + [voiceButton] }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rows = bounds.width > 500 ? 1 : 2     // >500 = 横屏 → 1 行;否则竖屏 → 2 行
        if rows != currentRows { setRows(rows) }
    }

    private func setRows(_ rows: Int) {
        currentRows = rows
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let btns = allButtons
        let perRow = Int(ceil(Double(btns.count) / Double(rows)))
        for r in 0..<rows {
            let row = UIStackView()
            row.axis = .horizontal; row.spacing = 5; row.distribution = .fillEqually; row.alignment = .fill
            for i in (r * perRow)..<min((r + 1) * perRow, btns.count) { row.addArrangedSubview(btns[i]) }
            container.addArrangedSubview(row)
        }
        containerHeightC.constant = CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowSpacing
        invalidateIntrinsicContentSize()
    }

    private func makeButton(symbol: String, sub: String, tap action: TerminalKeyAction) -> UIButton {
        let b = styledButton(symbol: symbol, sub: sub)
        // 按压视觉反馈:按下时背景变亮(所有普通键)。
        b.configurationUpdateHandler = { btn in
            var c = btn.configuration
            c?.background.backgroundColor = btn.isHighlighted ? UIColor(white: 1, alpha: 0.34) : UIColor(white: 1, alpha: 0.12)
            btn.configuration = c
        }
        b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        return b
    }

    private func makeVoiceButton() -> UIButton {
        let b = styledButton(symbol: "🎤", sub: "语音")
        // hold-to-talk 用 long-press(minimumPressDuration 0):一次连续触摸 = 一个 .began(voiceDown)+
        // 一个 .ended(voiceUp),**不会重复**。touchDown/touchUpInside 在 inputAccessoryView + 音频会话激活下
        // 观测到 voiceDown 疯狂重复触发(录音被不断 cancel+重启 → 录不到)。
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(voiceLongPress(_:)))
        lp.minimumPressDuration = 0
        b.addGestureRecognizer(lp)
        return b
    }

    @objc private func voiceLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            setVoiceActive(true)               // 视觉:按钮变红(录音中);震动在 VC handleKeyBarAction 里(主窗口上下文)
            onAction?(.voiceDown)
        case .ended, .cancelled, .failed:
            setVoiceActive(false)
            onAction?(.voiceUp)
        default: break
        }
    }

    private func setVoiceActive(_ active: Bool) {
        var cfg = voiceButton.configuration
        cfg?.background.backgroundColor = active ? UIColor.systemRed.withAlphaComponent(0.9)
                                                 : UIColor(white: 1, alpha: 0.12)
        voiceButton.configuration = cfg
    }

    /// index.html `.kc` 风格:大符号(kl)+ 小副标题(ks)。Configuration 的 title/subtitle 两级。
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
