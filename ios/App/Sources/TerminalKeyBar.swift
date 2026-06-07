import UIKit

/// 终端控制键动作。文本输入靠语音/硬件键;这里是终端控制键(迷你条用 esc/enter,其余进 TerminalDrawer)。
enum TerminalKeyAction {
    case up, down, left, right, enter, esc, shiftTab, ctrlC, ctrlB, delWord, paste
}

/// 终端底部**常驻迷你条**(无硬件键盘时挂 SwiftTerm 的 `inputAccessoryView`)。
///
/// 布局:顶部抓柄(上滑展开 `TerminalDrawer`)+ 一行 `[Esc · 🎤 按住说话 · ⏎]`。
/// 低频键(方向键 / Paste / Del Word / Ctrl-B / Mode / Break)收进抽屉,平时不占不挡正文。
/// 语音:mic **按住说话**、**按住上滑转长录音**(手势经 `onVoiceGesture` 把 phase + 纵向位移给 VC,
/// 由 VC 复用既有 voiceDown/voiceUp + armed/`lockVoiceToRecording`)。mic 上长按手势在 begin 后
/// 全局跟踪手指,滑出 accessory 进终端区仍持续 `.changed`,故无跨窗口问题。
final class TerminalKeyBar: UIInputView {
    var onAction: ((TerminalKeyAction) -> Void)?
    /// mic 长按:phase + 相对按下点的纵向位移(上滑为负)。
    var onVoiceGesture: ((UIGestureRecognizer.State, CGFloat) -> Void)?
    /// 抓柄 pan:phase + 纵向位移(上滑为负)+ 纵向速度(用于落位弹簧的初速度)。
    var onHandlePan: ((UIGestureRecognizer.State, CGFloat, CGFloat) -> Void)?

    /// 由 VC 按 tmux copy-mode 状态驱动:true → Esc 变"安全绿" + 副标题"退出滚动"。
    var escCopyModeSafe: Bool = false {
        didSet { guard oldValue != escCopyModeSafe else { return }; escButton.setNeedsUpdateConfiguration() }
    }

    private static let rowHeight: CGFloat = 44
    private static let topStrip: CGFloat = 18      // 抓柄区
    private static let hSpacing: CGFloat = 8
    private static let hInset: CGFloat = 10
    private static let vInset: CGFloat = 6
    private static let pillTag = 99

    private let escButton = UIButton(type: .system)
    private let enterButton = UIButton(type: .system)
    private let micButton = UIButton(type: .custom)
    private let handle = UIView()
    private var micStartY: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight(width: bounds.width, bottomInset: safeAreaInsets.bottom))
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout(); invalidateIntrinsicContentSize()
    }

    /// 迷你条恒单行;`width` 参数保留只为调用面兼容(不影响高度)。
    static func preferredHeight(width: CGFloat, bottomInset: CGFloat) -> CGFloat {
        topStrip + rowHeight + vInset * 2 + bottomInset
    }

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.preferredHeight(width: width, bottomInset: 0)), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        allowsSelfSizing = true
        overrideUserInterfaceStyle = .dark
        backgroundColor = TermStyle.chrome

        // 抓柄(上滑展开抽屉)
        addSubview(handle)
        let pill = UIView()
        pill.tag = Self.pillTag
        pill.backgroundColor = TermStyle.grab
        pill.layer.cornerRadius = 2.5
        handle.addSubview(pill)
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        // Esc
        configurePlainKey(escButton, title: "⎋", sub: "Esc", esc: true)
        escButton.configurationUpdateHandler = { [weak self] b in self?.applyEscConfiguration(b) }
        escButton.addAction(UIAction { [weak self] _ in self?.onAction?(.esc) }, for: .touchUpInside)
        escButton.addPressFX()
        addSubview(escButton)

        // Enter
        configurePlainKey(enterButton, title: "↵", sub: "Enter", esc: false)
        enterButton.addAction(UIAction { [weak self] _ in self?.onAction?(.enter) }, for: .touchUpInside)
        enterButton.addPressFX()
        addSubview(enterButton)

        // Mic(按住说话 / 上滑转录音)
        var mcfg = UIButton.Configuration.plain()
        mcfg.background.backgroundColor = UIColor(red: 0.17, green: 0.31, blue: 0.23, alpha: 1)
        mcfg.background.cornerRadius = TermStyle.radius
        mcfg.background.strokeColor = TermStyle.accent
        mcfg.background.strokeWidth = 1
        var mt = AttributedString("🎤 按住说话"); mt.font = .systemFont(ofSize: 14, weight: .semibold)
        mcfg.attributedTitle = mt
        micButton.configuration = mcfg
        micButton.tintColor = UIColor(red: 0.85, green: 0.95, blue: 0.89, alpha: 1)
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(micGesture(_:)))
        lp.minimumPressDuration = 0
        micButton.addGestureRecognizer(lp)
        addSubview(micButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let left = Self.hInset + safeAreaInsets.left
        let right = Self.hInset + safeAreaInsets.right
        let rowY = Self.topStrip + Self.vInset

        handle.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.topStrip + 4)
        handle.viewWithTag(Self.pillTag)?.frame = CGRect(x: (bounds.width - 40) / 2, y: 8, width: 40, height: 5)

        let escW: CGFloat = 54
        let enterW: CGFloat = 66
        escButton.frame = CGRect(x: left, y: rowY, width: escW, height: Self.rowHeight)
        enterButton.frame = CGRect(x: bounds.width - right - enterW, y: rowY, width: enterW, height: Self.rowHeight)
        let micX = left + escW + Self.hSpacing
        let micW = (bounds.width - right - enterW - Self.hSpacing) - micX
        micButton.frame = CGRect(x: micX, y: rowY, width: max(0, micW), height: Self.rowHeight)
    }

    @objc private func micGesture(_ g: UILongPressGestureRecognizer) {
        let y = g.location(in: self).y
        switch g.state {
        case .began: micStartY = y; micButton.pressFX(down: true)
        case .ended, .cancelled, .failed: micButton.pressFX(down: false)
        default: break
        }
        onVoiceGesture?(g.state, y - micStartY)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        onHandlePan?(g.state, g.translation(in: self).y, g.velocity(in: self).y)
    }

    private func configurePlainKey(_ b: UIButton, title: String, sub: String, esc: Bool) {
        var cfg = UIButton.Configuration.plain()
        cfg.background.backgroundColor = TermStyle.keyBg
        cfg.background.cornerRadius = TermStyle.keyRadius
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        var t = AttributedString(title); t.font = .systemFont(ofSize: 19, weight: .bold)
        cfg.attributedTitle = t
        var s = AttributedString(sub); s.font = .systemFont(ofSize: 8, weight: .regular)
        cfg.attributedSubtitle = s
        cfg.titlePadding = 1
        cfg.titleAlignment = .center
        b.configuration = cfg
        b.tintColor = TermStyle.ink
        if !esc {
            b.configurationUpdateHandler = { btn in
                var c = btn.configuration
                c?.background.backgroundColor = btn.isHighlighted ? TermStyle.keyHighlight : TermStyle.keyBg
                btn.configuration = c
            }
        }
    }

    /// Esc 配色:copy-mode 安全态 = 绿底 + "退出滚动";常态 = 中性灰 + "Esc"。
    private func applyEscConfiguration(_ btn: UIButton) {
        var c = btn.configuration
        if escCopyModeSafe {
            c?.background.backgroundColor = btn.isHighlighted
                ? UIColor(red: 0.26, green: 0.66, blue: 0.44, alpha: 1)
                : UIColor(red: 0.17, green: 0.52, blue: 0.34, alpha: 1)
            var sub = AttributedString("退出滚动"); sub.font = .systemFont(ofSize: 7, weight: .semibold)
            c?.attributedSubtitle = sub
        } else {
            c?.background.backgroundColor = btn.isHighlighted ? TermStyle.keyHighlight : TermStyle.keyBg
            var sub = AttributedString("Esc"); sub.font = .systemFont(ofSize: 8, weight: .regular)
            c?.attributedSubtitle = sub
        }
        btn.configuration = c
    }
}
