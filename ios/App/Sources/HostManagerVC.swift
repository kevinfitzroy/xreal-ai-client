import UIKit

/// 「管理 Host」页(列表态 nav bar 齿轮进入):列出已配置的 host,**滑动删除**(带确认)。
/// 只动本地配置 + 私钥文件(HostStore.deleteHost),服务器侧不受影响。
///
/// SECURITY:只显示 name + addr(别名),**绝不显示真实 IP**(`ssh.host`)——与列表 section header 一致。
/// 删除有二次确认(destructive,不可逆:连私钥一起删)。改动在 `onDone(changed:)` 一次性回灌给 VC。
final class HostManagerVC: UITableViewController {
    /// 关闭时回调:changed=true 表示这次有删除,调用方需 reload hosts。
    var onDone: ((_ changed: Bool) -> Void)?

    private var hosts: [HostConfig]
    private var changed = false

    init(hosts: [HostConfig]) {
        self.hosts = hosts
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理 Host"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "h")
    }

    @objc private func done() {
        dismiss(animated: true) { [changed, onDone] in onDone?(changed) }
    }

    // 用户点 X / 下滑关闭(非「完成」)也要回灌改动。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDone?(changed); onDone = nil }
    }

    // MARK: - Table
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { hosts.count }

    override func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? {
        hosts.isEmpty ? nil : "左滑删除 host"
    }
    override func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        hosts.isEmpty
            ? "暂无 host。AirDrop 一个 .xrhosts 配置导入。"
            : "删除只移除本机配置与私钥,不影响服务器。"
    }

    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "h", for: ip)
        let h = hosts[ip.row]
        var cfg = UIListContentConfiguration.subtitleCell()
        cfg.text = h.name
        let proxy = h.proxy.map { "  ·  🔒 \($0.name)" } ?? ""
        cfg.secondaryText = h.addr + proxy   // 只别名,不露真实 IP
        cfg.secondaryTextProperties.color = .secondaryLabel
        cfg.image = UIImage(systemName: "server.rack")
        cfg.imageProperties.tintColor = .systemGray
        cell.contentConfiguration = cfg
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ t: UITableView,
                            trailingSwipeActionsConfigurationForRowAt ip: IndexPath)
        -> UISwipeActionsConfiguration? {
        let del = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, finish in
            self?.confirmDelete(at: ip, finish: finish)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }

    private func confirmDelete(at ip: IndexPath, finish: @escaping (Bool) -> Void) {
        guard ip.row < hosts.count else { finish(false); return }
        let h = hosts[ip.row]
        let a = UIAlertController(
            title: "删除 host「\(h.name)」?",
            message: "将移除本机的配置与私钥文件(不可恢复)。服务器与远端 session 不受影响。",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in finish(false) })
        a.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { finish(false); return }
            let ok = HostStore.deleteHost(named: h.name)
            finish(false)   // 不让系统自动删行,下面手动带动画删
            guard ok, ip.row < self.hosts.count else { return }
            self.changed = true
            self.hosts.remove(at: ip.row)
            self.tableView.performBatchUpdates {
                self.tableView.deleteRows(at: [ip], with: .automatic)
            } completion: { _ in
                // 删空 → 刷 footer 文案
                self.tableView.reloadSections(IndexSet(integer: 0), with: .none)
            }
        })
        present(a, animated: true)
    }
}
