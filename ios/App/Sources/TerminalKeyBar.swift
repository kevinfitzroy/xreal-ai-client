import UIKit

/// 触屏虚拟键盘的动作。文本输入靠语音/硬件键,这里只放终端控制键。
enum TerminalKeyAction {
    case up, down, left, right, enter, esc, shiftTab, ctrlC, ctrlB, delWord
}

/// 触屏虚拟键盘(原生),**无硬件键盘时**挂为 SwiftTerm 的 `inputAccessoryView`。
///
/// 横屏单行:
/// esc left up down right delete-word ctrl-b shift-tab ctrl-c enter enter
///
/// 竖屏双行:
/// esc up   empty delete-word ctrl-b enter
/// left down right shift-tab   ctrl-c enter
///
/// Enter 在单行占 2 格,双行占最右侧整列。返回靠手势,语音靠 terminal 底部热区,不再占 vkey。
final class TerminalKeyBar: UIInputView {
    var onAction: ((TerminalKeyAction) -> Void)?

    private static let rowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 5
    private static let hSpacing: CGFloat = 5
    private static let hInset: CGFloat = 5
    private static let vInset: CGFloat = 5

    private var buttons: [TerminalKeyAction: UIButton] = [:]
    private var currentRows = 0

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
            let b = makeButton(symbol: spec.symbol, sub: spec.sub, tap: spec.action)
            buttons[spec.action] = b
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

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
        let actions: [TerminalKeyAction] = [.esc, .left, .up, .down, .right, .delWord, .ctrlB, .shiftTab, .ctrlC]
        let content = contentRect(rows: 1)
        let cols: CGFloat = 11
        let cellW = (content.width - Self.hSpacing * (cols - 1)) / cols
        let y = content.minY
        for (i, action) in actions.enumerated() {
            place(action, x: content.minX + CGFloat(i) * (cellW + Self.hSpacing), y: y, w: cellW, h: Self.rowHeight)
        }
        place(.enter, x: content.minX + 9 * (cellW + Self.hSpacing), y: y, w: cellW * 2 + Self.hSpacing, h: Self.rowHeight)
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
        // col 2 is intentionally empty.
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

    private static let keySpecs: [(symbol: String, sub: String, action: TerminalKeyAction)] = [
        ("⎋", "Esc", .esc),
        ("←", "", .left),
        ("↑", "", .up),
        ("↓", "", .down),
        ("→", "", .right),
        ("⌫", "删词", .delWord),
        ("^B", "Ctrl-B", .ctrlB),
        ("⇧⇥", "模式", .shiftTab),
        ("^C", "中断", .ctrlC),
        ("↵", "Enter", .enter),
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

    private func makeButton(symbol: String, sub: String, tap action: TerminalKeyAction) -> UIButton {
        let b = styledButton(symbol: symbol, sub: sub)
        b.configurationUpdateHandler = { btn in
            var c = btn.configuration
            c?.background.backgroundColor = btn.isHighlighted ? UIColor(white: 1, alpha: 0.34) : UIColor(white: 1, alpha: 0.12)
            btn.configuration = c
        }
        b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        return b
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
