import UIKit

/// **轻量打字输入 overlay(方案二)** —— 覆盖终端、用系统原生键盘打字,确认后整段注入 SSH。
///
/// 设计要点(见 issue「iOS 轻量打字输入」):
/// - 一张贴顶的输入卡(`UITextView`)+ 系统键盘(中文/英文/符号全有,白嫖原生 IME)。
/// - 键盘上方挂一条 `inputAccessoryView` 快捷键条:`/` `?` `!` 等符号 + `/compact` `/context` 等命令片段
///   + 「取消 / 送出」。chip 点击 = 在光标处 `insertText`。
/// - 自身全覆盖终端 → 输入时不需要看下面内容。**frame 冻结由 VC 负责**(本视图不碰 term)。
/// - 注入语义:`onSubmit(text)` 交给 VC 决定是否追加 `\n`(见 issue 决策点)。
final class TypedInputOverlay: UIView {

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// accessory 条上的快捷插入项(待定,见 issue;后续可由热词/命令体系动态生成)。
    private static let chips = ["/", "?", "!", "|", "-", "~", "/compact", "/context", "/status", "/usage", "/clear", "/resume"]

    private let textView = UITextView()
    private let placeholder = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = UIColor.black.withAlphaComponent(0.92)   // 近全覆盖:进入独立打字态

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        textView.textColor = .white
        textView.tintColor = .systemGreen
        textView.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        textView.layer.cornerRadius = 10
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.keyboardAppearance = .dark
        textView.delegate = self
        textView.inputAccessoryView = makeAccessoryBar()
        addSubview(textView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "打字输入,送出后整段注入终端"
        placeholder.textColor = UIColor(white: 0.5, alpha: 1)
        placeholder.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        placeholder.isUserInteractionEnabled = false
        addSubview(placeholder)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 180),   // 贴顶固定高 → 始终在键盘上方
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 14),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 17),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 唤起:清空、显示、抢键盘(系统键盘弹出)。
    func present() {
        textView.text = ""
        placeholder.isHidden = false
        isHidden = false
        textView.becomeFirstResponder()
    }

    /// 收起:放键盘、隐藏。
    func dismissOverlay() {
        textView.resignFirstResponder()
        isHidden = true
    }

    // MARK: - accessory 快捷键条

    private func makeAccessoryBar() -> UIView {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 184))   // 高些 → 候选键多行
        bar.backgroundColor = UIColor(white: 0.16, alpha: 1)
        bar.autoresizingMask = .flexibleWidth

        // 候选键:多行自动换行(不用左右拖)
        let flow = ChipFlowView(chips: Self.chips.map { chipButton($0) })
        flow.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(flow)

        // 底部按钮行:Cancel(左)/ Send(右)
        let cancel = barButton("Cancel", color: .systemRed, action: #selector(tapCancel))
        let send = barButton("Send", color: .systemGreen, action: #selector(tapSubmit))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        send.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(cancel); bar.addSubview(send)

        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            flow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            flow.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            flow.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -6),

            cancel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            cancel.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            send.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            send.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
        ])
        return bar
    }

    private func barButton(_ title: String, color: UIColor, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(color, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func chipButton(_ s: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(s, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        b.backgroundColor = UIColor(white: 0.28, alpha: 1)
        b.layer.cornerRadius = 7
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        b.accessibilityLabel = s
        b.addTarget(self, action: #selector(tapChip(_:)), for: .touchUpInside)
        return b
    }

    @objc private func tapChip(_ sender: UIButton) {
        guard let s = sender.currentTitle else { return }
        textView.insertText(s)   // 在光标处插入
    }

    @objc private func tapCancel() { onCancel?() }

    @objc private func tapSubmit() {
        let t = textView.text ?? ""
        onSubmit?(t)
    }
}

extension TypedInputOverlay: UITextViewDelegate {
    func textViewDidChange(_ tv: UITextView) {
        placeholder.isHidden = !tv.text.isEmpty
    }
}

/// 候选键的**自动换行(flow)**容器:按可用宽度从左到右排,放不下就换行 —— 不用横向拖。
private final class ChipFlowView: UIView {
    private let chips: [UIButton]
    private let hGap: CGFloat = 8, vGap: CGFloat = 8, rowH: CGFloat = 34

    init(chips: [UIButton]) {
        self.chips = chips
        super.init(frame: .zero)
        chips.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxW = bounds.width
        guard maxW > 0 else { return }
        var x: CGFloat = 0, y: CGFloat = 0
        for b in chips {
            b.sizeToFit()
            let w = min(b.bounds.width, maxW)
            if x > 0, x + w > maxW { x = 0; y += rowH + vGap }   // 超出本行宽度 → 换行
            b.frame = CGRect(x: x, y: y, width: w, height: rowH)
            x += w + hGap
        }
    }
}
