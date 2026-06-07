import UIKit

/// 终端低频键的上拉抽屉(VC 管理的覆盖层,默认收起)。展开时由 VC **挤压终端区**(终端缩小 reflow),
/// 抽屉占住底部腾出的空间——不遮挡正文、无变暗遮罩;面板之上的触摸穿透给终端(终端仍可用)。
/// 3×3 零空位(mock v8):
/// ```
/// Paste     Del Word   ^C Break
/// ⇧⇥ Mode   ↑          ^B Ctrl-B
/// ←         ↓          →
/// ```
/// 方向键蓝调、Break 红调。键动作复用 `TerminalKeyAction` → VC `handleKeyBarAction`。下滑面板收起。
final class TerminalDrawer: UIView {
    var onAction: ((TerminalKeyAction) -> Void)?
    var onDismiss: (() -> Void)?

    private let panel = UIView()
    private let grabPill = UIView()
    private var buttons: [UIButton] = []
    private var progress: CGFloat = 0       // 0 收起 → 1 展开
    private var panelHeight: CGFloat = 0
    private var repeatTimer: Timer?

    /// 展开时占用的高度(供 VC 扣进 termBaseFrame 挤压终端)。
    var openHeight: CGFloat {
        if panelHeight <= 0 { panelHeight = computePanelHeight() }
        return panelHeight
    }

    private enum Kind { case normal, arrow, brk }
    private struct Spec { let title: String; let sub: String; let action: TerminalKeyAction; let kind: Kind }
    private static let specs: [Spec] = [
        Spec(title: "Paste", sub: "",        action: .paste,    kind: .normal),
        Spec(title: "⌫",     sub: "Del Word", action: .delWord,  kind: .normal),
        Spec(title: "^C",    sub: "Break",    action: .ctrlC,    kind: .brk),
        Spec(title: "⇧⇥",    sub: "Mode",     action: .shiftTab, kind: .normal),
        Spec(title: "↑",     sub: "",         action: .up,       kind: .arrow),
        Spec(title: "^B",    sub: "Ctrl-B",   action: .ctrlB,    kind: .normal),
        Spec(title: "←",     sub: "",         action: .left,     kind: .arrow),
        Spec(title: "↓",     sub: "",         action: .down,     kind: .arrow),
        Spec(title: "→",     sub: "",         action: .right,    kind: .arrow),
    ]
    private static let cols = 3
    private static let cellH: CGFloat = 46
    private static let gap: CGFloat = 8
    private static let hInset: CGFloat = 14
    private static let grabArea: CGFloat = 22
    private static let bottomPad: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = .clear

        panel.backgroundColor = TermStyle.surface
        panel.layer.cornerRadius = 16
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.layer.borderWidth = 1
        panel.layer.borderColor = TermStyle.border.cgColor
        addSubview(panel)

        grabPill.backgroundColor = TermStyle.grab
        grabPill.layer.cornerRadius = 2.5
        panel.addSubview(grabPill)
        panel.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panelPan(_:))))

        for s in Self.specs {
            let b = makeButton(s)
            panel.addSubview(b)
            buttons.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// 只接面板区域的触摸;面板之上(终端区)穿透 → 终端不被挡、仍可用。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    private func makeButton(_ s: Spec) -> UIButton {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.plain()
        cfg.background.cornerRadius = TermStyle.keyRadius
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        cfg.background.strokeWidth = 1
        switch s.kind {
        case .normal:
            cfg.background.backgroundColor = TermStyle.keyBg
            cfg.background.strokeColor = TermStyle.keyBorder
        case .arrow:
            cfg.background.backgroundColor = TermStyle.arrowBg
            cfg.background.strokeColor = TermStyle.arrowBorder
        case .brk:
            cfg.background.backgroundColor = TermStyle.dangerBg
            cfg.background.strokeColor = TermStyle.dangerBorder
        }
        var t = AttributedString(s.title)
        t.font = .systemFont(ofSize: s.kind == .arrow ? 18 : (s.title.count > 1 ? 14 : 18), weight: .semibold)
        cfg.attributedTitle = t
        if !s.sub.isEmpty {
            var sub = AttributedString(s.sub); sub.font = .systemFont(ofSize: 8, weight: .regular)
            cfg.attributedSubtitle = sub; cfg.titlePadding = 1
        }
        cfg.titleAlignment = .center
        b.configuration = cfg
        b.tintColor = s.kind == .arrow ? TermStyle.arrowInk
                    : s.kind == .brk   ? TermStyle.dangerInk
                    :                    TermStyle.ink
        if s.action == .delWord {
            b.addTarget(self, action: #selector(delWordDown), for: .touchDown)
            b.addTarget(self, action: #selector(repeatUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        } else {
            let action = s.action
            b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        }
        b.addPressFX()   // 轻触感 + 按压缩放
        return b
    }

    private func computePanelHeight() -> CGFloat {
        let rows = (Self.specs.count + Self.cols - 1) / Self.cols
        return Self.grabArea + CGFloat(rows) * Self.cellH + CGFloat(rows - 1) * Self.gap + Self.bottomPad + safeAreaInsets.bottom
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        panelHeight = computePanelHeight()
        layoutPanel()
    }

    private func layoutPanel() {
        let topY = bounds.height - panelHeight * progress
        panel.frame = CGRect(x: 0, y: topY, width: bounds.width, height: panelHeight + 60)  // +60 垫底,圆角下方不穿帮
        grabPill.frame = CGRect(x: (bounds.width - 40) / 2, y: 8, width: 40, height: 5)
        let left = Self.hInset + safeAreaInsets.left
        let contentW = bounds.width - left - (Self.hInset + safeAreaInsets.right)
        let cw = (contentW - Self.gap * CGFloat(Self.cols - 1)) / CGFloat(Self.cols)
        for (i, b) in buttons.enumerated() {
            let r = i / Self.cols, c = i % Self.cols
            b.frame = CGRect(x: left + CGFloat(c) * (cw + Self.gap),
                             y: Self.grabArea + CGFloat(r) * (Self.cellH + Self.gap),
                             width: cw, height: Self.cellH)
        }
    }

    // MARK: 开合(由迷你条抓柄 / 自身手势驱动)

    func present(in container: CGRect) {
        frame = container
        setNeedsLayout(); layoutIfNeeded()
        isHidden = false
    }

    func drag(toProgress p: CGFloat) {
        progress = max(0, min(1, p))
        layoutPanel()
    }

    /// 落位:弹簧(不回弹)+ 吃松手速度。落点给一下触感。尊重「减弱动态」。
    func settle(open: Bool, velocity: CGFloat = 0) {
        isHidden = false
        Haptics.light.impactOccurred()
        let reduce = UIAccessibility.isReduceMotionEnabled
        let remaining = max(1, panelHeight * (open ? (1 - progress) : progress))
        let v = min(8, abs(velocity) / remaining)
        UIView.animate(withDuration: reduce ? 0 : 0.42, delay: 0,
                       usingSpringWithDamping: 0.86, initialSpringVelocity: reduce ? 0 : v,
                       options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.progress = open ? 1 : 0
            self.layoutPanel()
        } completion: { _ in
            if !open { self.isHidden = true; self.onDismiss?() }
        }
    }

    func dismiss() {
        stopRepeat()
        guard !isHidden else { return }
        settle(open: false)
    }

    @objc private func panelPan(_ g: UIPanGestureRecognizer) {
        let ty = g.translation(in: self).y
        switch g.state {
        case .changed:
            drag(toProgress: 1 - ty / max(1, panelHeight))   // 下滑 ty>0 → progress 减
        case .ended, .cancelled, .failed:
            settle(open: ty < panelHeight * 0.3, velocity: g.velocity(in: self).y)   // 下滑不到三成 → 弹回展开
        default:
            break
        }
    }

    // MARK: Del Word 长按连删(复用原 keybar 节奏)

    @objc private func delWordDown() { startRepeat() }
    @objc private func repeatUp() { stopRepeat() }
    private func startRepeat() {
        stopRepeat()
        onAction?(.delWord)
        let t = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in self?.onAction?(.delWord) }
        RunLoop.main.add(t, forMode: .common)
        t.fireDate = Date().addingTimeInterval(0.36)
        repeatTimer = t
    }
    private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil }
}
