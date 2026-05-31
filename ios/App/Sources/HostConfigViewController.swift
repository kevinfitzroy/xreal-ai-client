import UIKit
import UniformTypeIdentifiers

/// Native config page (SPEC §8) reached from the list view — semantically the F2/back target
/// the hardware keys will eventually drive; until then a visible "配置" button on the list opens
/// it. Deliberately NOT folded into the shared `index.html` SPA (keeps the WebView a clean Agent
/// Deck). Three document-picker buttons funnel into the SAME `HostStore.importConfig`, which
/// auto-detects mode (single→append / global→replace / asr); a mismatch vs the button's intent is
/// surfaced clearly. Also shows the current config summary so the user knows their state.
///
/// On a successful import it hands the `ImportResult` back through `onImported` so the owner
/// (TerminalViewController) runs the single reload path; this page just refreshes its own summary.
final class HostConfigViewController: UIViewController, UIDocumentPickerDelegate {

    /// Called after a successful import so the owner reloads the list (reloadHostsAfterImport).
    var onImported: ((HostStore.ImportResult) -> Void)?

    /// What the tapped button expected — used only to warn when the file's actual shape differs.
    private enum Intent { case single, global, asr }
    private var pendingIntent: Intent = .single

    private let summaryLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0x0D/255, green: 0x0F/255, blue: 0x16/255, alpha: 1)  // #0D0F16
        title = "Host 配置"

        // Done button to return to the list (semantic back / F2).
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])

        summaryLabel.numberOfLines = 0
        summaryLabel.textColor = UIColor(white: 0.78, alpha: 1)
        summaryLabel.font = .systemFont(ofSize: 17, weight: .regular)
        summaryLabel.textAlignment = .center
        stack.addArrangedSubview(summaryLabel)
        stack.setCustomSpacing(28, after: summaryLabel)

        stack.addArrangedSubview(makeButton("导入单个 host", action: #selector(pickSingle)))
        stack.addArrangedSubview(makeButton("导入全局 hosts", action: #selector(pickGlobal)))
        stack.addArrangedSubview(makeButton("导入 ASR 凭证", action: #selector(pickAsr)))

        refreshSummary()
    }

    private func makeButton(_ title: String, action: Selector) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.baseBackgroundColor = UIColor(red: 0x94/255, green: 0xE0/255, blue: 0xB2/255, alpha: 1)  // #94E0B2
        cfg.baseForegroundColor = UIColor(red: 0x0D/255, green: 0x0F/255, blue: 0x16/255, alpha: 1)
        cfg.cornerStyle = .large
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        let b = UIButton(configuration: cfg)
        b.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func refreshSummary() {
        let s = HostStore.configSummary()
        summaryLabel.text = "当前配置:\(s.hosts) 个 host · ASR \(s.asr ? "已配置" : "未配置")"
    }

    @objc private func close() { dismiss(animated: true) }

    // MARK: - Pickers (one per intent; all route to the same importConfig)
    @objc private func pickSingle() { pendingIntent = .single; presentPicker() }
    @objc private func pickGlobal() { pendingIntent = .global; presentPicker() }
    @objc private func pickAsr()    { pendingIntent = .asr;    presentPicker() }

    /// Allow our exported `.xrhosts` UTI plus generic JSON/data so a plain `.json` Valet export is
    /// also selectable. (The on-disk extension doesn't decide the mode — `importConfig` reads the
    /// content; this is purely which files the picker greys out.)
    private func presentPicker() {
        var types: [UTType] = [.json, .data]
        if let xr = UTType("io.github.kevinfitzroy.xrealclient.hosts") { types.insert(xr, at: 0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // asCopy:true gives an app-owned temp copy, but keep the scoped-access pattern for safety.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try HostStore.importConfig(from: url)
            refreshSummary()
            onImported?(result)
            presentResult(result)
        } catch {
            NSLog("[HostConfig] import failed: \(error)")
            alert("导入失败", "\(error)")
        }
    }

    /// Confirm what landed, and clearly flag when the file's detected shape doesn't match the
    /// button the user tapped (e.g. tapped "导入单个 host" but the file was a global list).
    private func presentResult(_ r: HostStore.ImportResult) {
        let actual: String
        switch r.mode {
        case .append:  actual = "单个 host(追加)"
        case .replace: actual = "全局 hosts(替换)"
        case .asrOnly: actual = "ASR 凭证"
        }
        let expectedMode: HostStore.ImportMode = pendingIntent == .single ? .append
            : (pendingIntent == .global ? .replace : .asrOnly)

        var lines: [String] = []
        if r.mode != .asrOnly {
            lines.append(r.mode == .append ? "追加了 \(r.hosts) 个 host" : "替换为 \(r.hosts) 个 host")
        }
        if r.asr { lines.append("ASR 凭证已写入") }
        if lines.isEmpty { lines.append("已处理") }

        // The mode is decided by file content, not the button. Warn on mismatch so the user isn't
        // surprised (a "导入单个 host" tap that replaced the whole list, etc.).
        let mismatch = (r.mode != expectedMode) && !(expectedMode == .asrOnly && r.asr)
        let title = mismatch ? "已按文件内容导入" : "导入成功"
        var body = lines.joined(separator:"、")
        if mismatch { body += "\n\n(文件实际是「\(actual)」,与所选按钮不同 —— 已按文件内容处理)" }
        alert(title, body)
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
}
