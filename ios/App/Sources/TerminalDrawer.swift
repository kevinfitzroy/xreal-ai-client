import UIKit

/// 终端低频键的上拉抽屉(VC 管理的覆盖层,默认收起)。由迷你条抓柄上滑拉起;点遮罩 / 面板下滑收起。
/// 3×3 零空位,对齐设计 mock v8:
/// ```
/// Paste     Del Word   ^C Break
/// ⇧⇥ Mode   ↑          ^B Ctrl-B
/// ←         ↓          →
/// ```
/// 方向键蓝调、Break 红调。键动作复用 `TerminalKeyAction` → VC `handleKeyBarAction`。
final class TerminalDrawer: UIView {
    var onAction: ((TerminalKeyAction) -> Void)?
    var onDismiss: (() -> Void)?

    private let dim = UIView()
    private let panel = UIView()
    private let grabPill = UIView()
    private var buttons: [UIButton] = []
    private var progress: CGFloat = 0       // 0 收起 → 1 展开
    private var panelHeight: CGFloat = 0
    private var repeatTimer: Timer?

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

        dim.backgroundColor = UIColor(white: 0, alpha: 0.38)
        dim.alpha = 0
        addSubview(dim)
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTap)))

        panel.backgroundColor = UIColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 0.99)
        panel.layer.cornerRadius = 16
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(panel)

        grabPill.backgroundColor = UIColor(white: 0.42, alpha: 1)
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

    private func makeButton(_ s: Spec) -> UIButton {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.plain()
        cfg.background.cornerRadius = 10
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        cfg.background.strokeWidth = 1
        switch s.kind {
        case .normal:
            cfg.background.backgroundColor = UIColor(white: 1, alpha: 0.10)
            cfg.background.strokeColor = UIColor(white: 1, alpha: 0.16)
        case .arrow:
            cfg.background.backgroundColor = UIColor(red: 0.30, green: 0.40, blue: 0.60, alpha: 0.20)
            cfg.background.strokeColor = UIColor(red: 0.36, green: 0.44, blue: 0.60, alpha: 1)
        case .brk:
            cfg.background.backgroundColor = UIColor(red: 0.75, green: 0.22, blue: 0.17, alpha: 0.20)
            cfg.background.strokeColor = UIColor(red: 0.66, green: 0.22, blue: 0.18, alpha: 1)
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
        b.tintColor = s.kind == .arrow ? UIColor(red: 0.81, green: 0.88, blue: 1, alpha: 1)
                    : s.kind == .brk   ? UIColor(red: 1, green: 0.72, blue: 0.69, alpha: 1)
                    :                    UIColor(white: 0.92, alpha: 1)
        if s.action == .delWord {
            b.addTarget(self, action: #selector(delWordDown), for: .touchDown)
            b.addTarget(self, action: #selector(repeatUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        } else {
            let action = s.action
            b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        }
        return b
    }

    private func computePanelHeight() -> CGFloat {
        let rows = (Self.specs.count + Self.cols - 1) / Self.cols
        return Self.grabArea + CGFloat(rows) * Self.cellH + CGFloat(rows - 1) * Self.gap + Self.bottomPad + safeAreaInsets.bottom
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dim.frame = bounds
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

    /// 起手:就位(progress 保持当前,通常 0)并显示,后续 `drag(toProgress:)` 跟手抬升。
    func present(in container: CGRect) {
        frame = container
        setNeedsLayout(); layoutIfNeeded()
        isHidden = false
    }

    func drag(toProgress p: CGFloat) {
        progress = max(0, min(1, p))
        dim.alpha = progress
        layoutPanel()
    }

    func settle(open: Bool) {
        isHidden = false
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.progress = open ? 1 : 0
            self.dim.alpha = open ? 1 : 0
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

    @objc private func dimTap() { dismiss() }

    @objc private func panelPan(_ g: UIPanGestureRecognizer) {
        let ty = g.translation(in: self).y
        switch g.state {
        case .changed:
            drag(toProgress: 1 - ty / max(1, panelHeight))   // 下滑 ty>0 → progress 减
        case .ended, .cancelled, .failed:
            settle(open: ty < panelHeight * 0.3)             // 下滑不到三成 → 弹回展开,否则收起
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
