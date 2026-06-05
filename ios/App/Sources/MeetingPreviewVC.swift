import UIKit

/// 录音逐字稿预览页。**长内容适配**:语音转写通常很长 → 用可滚动、可选中(便于复制)的 `UITextView`,
/// 不是会截断的 alert。导航右上「委托」→ 选 subproject 投递;底部「删除」。委托走 `MeetingDelegate`(SFTP+send-keys)。
final class MeetingPreviewVC: UIViewController {

    private let recName: String
    private let markdown: String
    private let hosts: [HostConfig]
    private let onDelete: () -> Void

    private let textView = UITextView()
    private let toolbar = UIToolbar()
    private var blocker: UIView?

    private static let bg = UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1)

    init(name: String, markdown: String, hosts: [HostConfig], onDelete: @escaping () -> Void) {
        self.recName = name; self.markdown = markdown; self.hosts = hosts; self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = recName
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Self.bg

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTap))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "委托", style: .done, target: self, action: #selector(delegateTap))

        let shown = markdown.replacingOccurrences(of: "**", with: "")   // 预览去掉 markdown 加粗记号
        textView.text = shown
        textView.isEditable = false
        textView.isSelectable = true                 // 可长按复制
        textView.backgroundColor = .clear
        textView.textColor = UIColor(white: 0.92, alpha: 1)
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        toolbar.overrideUserInterfaceStyle = .dark
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let del = UIBarButtonItem(title: "删除", style: .plain, target: self, action: #selector(deleteTap))
        del.tintColor = .systemRed
        let count = UIBarButtonItem(title: "\(shown.count) 字", style: .plain, target: nil, action: nil)
        count.isEnabled = false
        toolbar.items = [del, UIBarButtonItem(systemItem: .flexibleSpace), count]
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @objc private func closeTap() { dismiss(animated: true) }

    @objc private func deleteTap() {
        let a = UIAlertController(title: "删除这条录音?", message: "音频和转写都会删掉。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.onDelete()
            self?.dismiss(animated: true)
        })
        present(a, animated: true)
    }

    @objc private func delegateTap() {
        let picker = SubprojectPickerVC(hosts: hosts) { [weak self] target in
            self?.runDelegation(to: target)
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func runDelegation(to target: MeetingDelegate.Target) {
        showBlocker("委托中…")
        Task { @MainActor in
            let result = await MeetingDelegate.deliver(transcript: markdown, name: recName, to: target)
            navigationController?.popToRootViewController(animated: false)   // 在 blocker 下收起选择器,回到预览页
            hideBlocker()
            let presenter = navigationController?.topViewController ?? self
            switch result {
            case .success:
                // 委托成功后确认是否删除 —— 可能委托错了地方,「保留」可再委托到别处。
                let a = UIAlertController(title: "已交给「\(target.projectName)」",
                                          message: "逐字稿已上传并转交。要删除这条录音吗?(委托错了可「保留」再重发)",
                                          preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "保留", style: .cancel) { [weak self] _ in
                    self?.dismiss(animated: true)   // 留着录音(可从 Home 再点开重委托),但一样退回 Home
                })
                a.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                    self?.onDelete()
                    self?.dismiss(animated: true)
                })
                presenter.present(a, animated: true)
            case .failure(let e):
                let a = UIAlertController(title: "委托失败", message: "\(e)", preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "好", style: .default))
                presenter.present(a, animated: true)
            }
        }
    }

    // MARK: - 阻塞式进度(委托是网络操作)

    private func showBlocker(_ text: String) {
        let host = navigationController?.view ?? view!
        let b = UIView(frame: host.bounds)
        b.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        b.backgroundColor = UIColor(white: 0, alpha: 0.55)
        let spin = UIActivityIndicatorView(style: .large)
        spin.color = .white; spin.startAnimating()
        spin.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = text; label.textColor = .white; label.font = .systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(spin); b.addSubview(label)
        NSLayoutConstraint.activate([
            spin.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            spin.centerYAnchor.constraint(equalTo: b.centerYAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            label.topAnchor.constraint(equalTo: spin.bottomAnchor, constant: 12),
        ])
        host.addSubview(b)
        blocker = b
    }

    private func hideBlocker() { blocker?.removeFromSuperview(); blocker = nil }
}
