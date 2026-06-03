import UIKit

/// 触屏虚拟键盘的动作。文本输入靠语音/硬件键,这里只放终端控制键。
enum TerminalKeyAction {
    case up, down, left, right, enter, esc, shiftTab, ctrlC, ctrlB, delWord, paste
}

/// 触屏虚拟键盘(原生),**无硬件键盘时**挂为 SwiftTerm 的 `inputAccessoryView`。
///
/// 横屏单行:
/// esc paste left up down right delete-word ctrl-b shift-tab ctrl-c enter enter
///
/// 竖屏双行:
/// esc up   paste delete-word ctrl-b enter
/// left down right shift-tab   ctrl-c enter
///
/// Enter 在单行占 2 格,双行占最右侧整列。返回靠手势,语音靠 terminal 底部热区,不再占 vkey。
/// paste(第一排第三格,原空缺)= 文字/图片粘贴,实际动作在 VC.handleKeyBarAction。
final class TerminalKeyBar: UIInputView {
    var onAction: ((TerminalKeyAction) -> Void)?

    /// 由 VC 按 tmux copy-mode 状态驱动:true → ESC 键变"安全绿" + 副标题"退出滚动"
    /// (提示此刻按 ESC 只退出翻页滚动,不会打断 Claude),减少误触 ESC 的心理负担。
    var escCopyModeSafe: Bool = false {
        didSet {
            guard oldValue != escCopyModeSafe else { return }
            buttons[.esc]?.setNeedsUpdateConfiguration()
        }
    }

    private static let rowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 5
    private static let hSpacing: CGFloat = 5
    private static let hInset: CGFloat = 5
    private static let vInset: CGFloat = 5

    private var buttons: [TerminalKeyAction: UIButton] = [:]
    private var currentRows = 0
    private var repeatTimer: Timer?
    private var repeatingAction: TerminalKeyAction?

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : frame.width
        return CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight(width: width, bottomInset: safeAreaInsets.bottom))
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.preferredHeight(width: width, bottomInset: 0)), inputViewStyle: .keyboard)
        currentRows = Self.rows(for: width)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        allowsSelfSizing = true
        overrideUserInterfaceStyle = .dark

        backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)

        for spec in Self.keySpecs {
            let b = makeButton(symbol: spec.symbol, sub: spec.sub, image: spec.image, tap: spec.action)
            buttons[spec.action] = b
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        stopRepeatingAction()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rows = Self.rows(for: bounds.width)
        if rows != currentRows {
            currentRows = rows
            invalidateIntrinsicContentSize()
        }
        rows == 1 ? layoutSingleRow() : layoutDoubleRow()
    }

    static func preferredHeight(width: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let rows = rows(for: width)
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing + vInset * 2 + bottomInset
    }

    private static func rows(for width: CGFloat) -> Int {
        width > 500 ? 1 : 2
    }

    private func layoutSingleRow() {
        buttons.values.forEach { $0.isHidden = false }
        configureEnter(compact: true)
        let actions: [TerminalKeyAction] = [.esc, .paste, .left, .up, .down, .right, .delWord, .ctrlB, .shiftTab, .ctrlC]
        let content = contentRect(rows: 1)
        let cols: CGFloat = 12
        let cellW = (content.width - Self.hSpacing * (cols - 1)) / cols
        let y = content.minY
        for (i, action) in actions.enumerated() {
            place(action, x: content.minX + CGFloat(i) * (cellW + Self.hSpacing), y: y, w: cellW, h: Self.rowHeight)
        }
        place(.enter, x: content.minX + 10 * (cellW + Self.hSpacing), y: y, w: cellW * 2 + Self.hSpacing, h: Self.rowHeight)
    }

    private func layoutDoubleRow() {
        buttons.values.forEach { $0.isHidden = false }
        configureEnter(compact: false)
        let content = contentRect(rows: 2)
        let cols: CGFloat = 6
        let cellW = (content.width - Self.hSpacing * (cols - 1)) / cols
        let y1 = content.minY
        let y2 = y1 + Self.rowHeight + Self.rowSpacing

        place(.esc,      x: colX(0, cellW, in: content), y: y1, w: cellW, h: Self.rowHeight)
        place(.up,       x: colX(1, cellW, in: content), y: y1, w: cellW, h: Self.rowHeight)
        place(.paste,    x: colX(2, cellW, in: content), y: y1, w: cellW, h: Self.rowHeight)
        place(.delWord,  x: colX(3, cellW, in: content), y: y1, w: cellW, h: Self.rowHeight)
        place(.ctrlB,    x: colX(4, cellW, in: content), y: y1, w: cellW, h: Self.rowHeight)

        place(.left,     x: colX(0, cellW, in: content), y: y2, w: cellW, h: Self.rowHeight)
        place(.down,     x: colX(1, cellW, in: content), y: y2, w: cellW, h: Self.rowHeight)
        place(.right,    x: colX(2, cellW, in: content), y: y2, w: cellW, h: Self.rowHeight)
        place(.shiftTab, x: colX(3, cellW, in: content), y: y2, w: cellW, h: Self.rowHeight)
        place(.ctrlC,    x: colX(4, cellW, in: content), y: y2, w: cellW, h: Self.rowHeight)

        place(.enter, x: colX(5, cellW, in: content), y: y1, w: cellW, h: Self.rowHeight * 2 + Self.rowSpacing)
    }

    private func contentRect(rows: Int) -> CGRect {
        let left = Self.hInset + safeAreaInsets.left
        let right = Self.hInset + safeAreaInsets.right
        let h = CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowSpacing
        return CGRect(x: left, y: Self.vInset, width: max(0, bounds.width - left - right), height: h)
    }

    private func colX(_ col: Int, _ cellW: CGFloat, in content: CGRect) -> CGFloat {
        content.minX + CGFloat(col) * (cellW + Self.hSpacing)
    }

    private func place(_ action: TerminalKeyAction, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        buttons[action]?.frame = CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
    }

    private static let keySpecs: [(symbol: String, sub: String, image: String?, action: TerminalKeyAction)] = [
        ("⎋", "Esc", nil, .esc),
        ("", "Paste", "doc.on.clipboard", .paste),   // 文字/图片粘贴;图标在上 + 标签在下,同其它键风格
        ("←", "", nil, .left),
        ("↑", "", nil, .up),
        ("↓", "", nil, .down),
        ("→", "", nil, .right),
        ("⌫", "Del Word", nil, .delWord),
        ("^B", "Ctrl-B", nil, .ctrlB),
        ("⇧⇥", "Mode", nil, .shiftTab),
        ("^C", "Break", nil, .ctrlC),
        ("↵", "Enter", nil, .enter),
    ]

    private func configureEnter(compact: Bool) {
        guard let b = buttons[.enter] else { return }
        var cfg = b.configuration ?? UIButton.Configuration.plain()
        if compact {
            var title = AttributedString("↵  Enter")
            title.font = .systemFont(ofSize: 18, weight: .bold)
            cfg.attributedTitle = title
            cfg.attributedSubtitle = nil
            cfg.titlePadding = 0
        } else {
            var title = AttributedString("↵")
            title.font = .systemFont(ofSize: 19, weight: .bold)
            cfg.attributedTitle = title
            var subt = AttributedString("Enter")
            subt.font = .systemFont(ofSize: 8, weight: .regular)
            cfg.attributedSubtitle = subt
            cfg.titlePadding = 1
        }
        cfg.titleAlignment = .center
        b.configuration = cfg
    }

    private func makeButton(symbol: String, sub: String, image: String?, tap action: TerminalKeyAction) -> UIButton {
        let b = styledButton(symbol: symbol, sub: sub, image: image)
        if action == .esc {
            b.configurationUpdateHandler = { [weak self] btn in self?.applyEscConfiguration(btn) }
        } else {
            b.configurationUpdateHandler = { btn in
                var c = btn.configuration
                c?.background.backgroundColor = btn.isHighlighted ? UIColor(white: 1, alpha: 0.34) : UIColor(white: 1, alpha: 0.12)
                btn.configuration = c
            }
        }
        if action == .delWord {
            b.addTarget(self, action: #selector(repeatableButtonDown(_:)), for: .touchDown)
            b.addTarget(self, action: #selector(repeatableButtonUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        } else {
            b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        }
        return b
    }

    /// ESC 键配色:copy-mode 安全态 = 绿底 + 副标题"退出滚动";常态 = 中性灰 + "Esc"。
    /// 每次 setNeedsUpdateConfiguration / 高亮变化都会重跑,据 [escCopyModeSafe] 二选一。
    private func applyEscConfiguration(_ btn: UIButton) {
        var c = btn.configuration
        if escCopyModeSafe {
            c?.background.backgroundColor = btn.isHighlighted
                ? UIColor(red: 0.26, green: 0.66, blue: 0.44, alpha: 1)
                : UIColor(red: 0.17, green: 0.52, blue: 0.34, alpha: 1)
            var sub = AttributedString("退出滚动")
            sub.font = .systemFont(ofSize: 7, weight: .semibold)
            c?.attributedSubtitle = sub
        } else {
            c?.background.backgroundColor = btn.isHighlighted ? UIColor(white: 1, alpha: 0.34) : UIColor(white: 1, alpha: 0.12)
            var sub = AttributedString("Esc")
            sub.font = .systemFont(ofSize: 8, weight: .regular)
            c?.attributedSubtitle = sub
        }
        btn.configuration = c
    }

    @objc private func repeatableButtonDown(_ sender: UIButton) {
        guard buttons[.delWord] === sender else { return }
        startRepeatingAction(.delWord)
    }

    @objc private func repeatableButtonUp(_ sender: UIButton) {
        guard buttons[.delWord] === sender else { return }
        stopRepeatingAction()
    }

    private func startRepeatingAction(_ action: TerminalKeyAction) {
        stopRepeatingAction()
        repeatingAction = action
        onAction?(action)
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            guard let self, let action = self.repeatingAction else { return }
            self.onAction?(action)
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        timer.fireDate = Date().addingTimeInterval(0.36)
    }

    private func stopRepeatingAction() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingAction = nil
    }

    /// index.html `.kc` 风格:大符号(kl)+ 小副标题(ks)。Configuration 的 title/subtitle 两级。
    /// `image`(SF Symbol 名)非空 → 图标键:图标在上 + 文字小标签在下,走 **image + title**
    /// (不用 subtitle —— 小键里 image+subtitle 会因空 title 退化叠在一起;粘贴键用此分支)。
    private func styledButton(symbol: String, sub: String, image: String? = nil) -> UIButton {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.plain()
        cfg.background.backgroundColor = UIColor(white: 1, alpha: 0.12)
        cfg.background.cornerRadius = 7
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        cfg.titleAlignment = .center
        if let image, let icon = UIImage(systemName: image) {
            cfg.image = icon
            cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            cfg.imagePlacement = .top
            cfg.imagePadding = 2
            // 小图标压不到底,整组居中会把标签顶高 → 加大顶部 inset 把内容下推,使标签落到与其它键小字同一线。
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 2, bottom: 1, trailing: 2)
            if !sub.isEmpty {
                var t = AttributedString(sub)
                t.font = .systemFont(ofSize: 8, weight: .regular)
                cfg.attributedTitle = t
            }
        } else {
            var title = AttributedString(symbol)
            title.font = .systemFont(ofSize: symbol.count > 1 ? 14 : 19, weight: .bold)
            cfg.attributedTitle = title
            if !sub.isEmpty {
                var subt = AttributedString(sub)
                subt.font = .systemFont(ofSize: 8, weight: .regular)
                cfg.attributedSubtitle = subt
                cfg.titlePadding = 1
            }
        }
        b.configuration = cfg
        b.tintColor = UIColor(white: 0.92, alpha: 1)
        return b
    }
}
