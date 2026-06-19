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
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 48))
        bar.backgroundColor = UIColor(white: 0.16, alpha: 1)
        bar.autoresizingMask = .flexibleWidth

        let cancel = barButton("取消", color: .systemRed, action: #selector(tapCancel))
        let send = barButton("送出", color: .systemGreen, action: #selector(tapSubmit))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        send.translatesAutoresizingMaskIntoConstraints = false

        // 中段:可横滚的 chip 行
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        for c in Self.chips {
            let b = chipButton(c)
            stack.addArrangedSubview(b)
        }
        scroll.addSubview(stack)
        bar.addSubview(cancel); bar.addSubview(scroll); bar.addSubview(send)

        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            send.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            send.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: cancel.trailingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -7),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
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
