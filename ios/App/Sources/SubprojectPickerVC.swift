import UIKit

/// 选一个 AI-agent subproject 作为委托目标。按 host 分组,**只列 claude/agent/maestro**
/// (ssh shell 不会处理文本,排除)。选中即回 `onPick` 一个 `MeetingDelegate.Target`(via 已解析)。
final class SubprojectPickerVC: UITableViewController {

    private struct Section { let host: HostConfig; let via: HostConfig?; let projects: [ProjectConfig] }
    private let sections: [Section]
    private let onPick: (MeetingDelegate.Target) -> Void

    init(hosts: [HostConfig], onPick: @escaping (MeetingDelegate.Target) -> Void) {
        self.onPick = onPick
        self.sections = hosts.compactMap { h in
            let ps = h.projects.filter { $0.type.isAiAgent }
            guard !ps.isEmpty else { return nil }
            let via = h.via.flatMap { vn in hosts.first { $0.name == vn } }
            return Section(host: h, via: via, projects: ps)
        }
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "委托给…"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .systemGroupedBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        if sections.isEmpty { showEmpty() }
    }

    private func showEmpty() {
        let l = UILabel()
        l.text = "没有可委托的 AI agent\n(当前只有 SSH shell,或暂无 project)"
        l.numberOfLines = 0; l.textAlignment = .center; l.textColor = .secondaryLabel
        l.font = .preferredFont(forTextStyle: .body)
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            l.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            l.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].projects.count }
    override func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? { sections[s].host.name }

    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "c", for: ip)
        let p = sections[ip.section].projects[ip.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = p.name
        cfg.secondaryText = p.type.rawValue
        cfg.image = UIImage(systemName: symbol(p.type))
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        let sec = sections[ip.section]
        let p = sec.projects[ip.row]
        onPick(.init(host: sec.host, via: sec.via, session: p.session, projectName: p.name))
    }

    private func symbol(_ t: ProjectType) -> String {
        switch t {
        case .claude:  return "sparkles"
        case .codex:   return "hexagon"
        case .agent:   return "cpu"
        case .maestro: return "command"
        case .ssh:     return "terminal"
        }
    }
}
