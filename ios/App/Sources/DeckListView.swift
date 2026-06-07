import UIKit

/// 一行 = 一个 project 的视图模型(状态已由 VC 按 SPEC §3 算好)。
struct DeckRow {
    let host: String
    let session: String
    let name: String
    let type: ProjectType
    let state: String?   // working|waiting|needs-permission|disconnected|unknown;nil = 未探测/加载中
    let since: Int       // epoch 秒(0=无)
    let loading: Bool
}

/// 一节 = 一个 host(section header)+ 其 projects。
struct DeckSection {
    let hostName: String
    let addr: String
    let proxy: String
    let up: Bool
    let rows: [DeckRow]
}

/// **原生** Agent Station 列表(iOS 全面原生化,采用苹果原生设计语言):insetGrouped UITableView、SF Symbols
/// 图标、系统色状态、disclosure 指示、下拉刷新、点 cell 进 project、滑动滚动。物理键盘(8BitDo)经 VC 调
/// `moveSelection`/`openSelected` 导航(触屏与物理键并存)。
final class DeckListView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onSelect: ((DeckRow) -> Void)?
    var onRefresh: (() -> Void)?

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private var sections: [DeckSection] = []
    private var selected = IndexPath(row: 0, section: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        // insetGrouped 标准配色:分组背景(浅灰/深),cell 用 secondarySystemGroupedBackground(白/深)→ 卡片边缘有对比。
        backgroundColor = .systemGroupedBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .systemGroupedBackground
        table.dataSource = self
        table.delegate = self
        table.register(DeckProjectCell.self, forCellReuseIdentifier: "cell")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 60
        let rc = UIRefreshControl()
        rc.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .valueChanged)
        table.refreshControl = rc
        addSubview(table)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: topAnchor),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setSections(_ s: [DeckSection]) {
        sections = s
        table.reloadData()
        clampSelection()
        table.refreshControl?.endRefreshing()
    }

    /// 空态文案(nil = 有数据,隐藏)。
    func setEmptyText(_ text: String?) {
        emptyLabel.text = text
        emptyLabel.isHidden = (text == nil)
    }

    // MARK: - 物理键导航(VC 在 pressesBegan 调)
    func moveSelection(_ delta: Int) {
        let order = flatIndexPaths
        guard !order.isEmpty else { return }
        let cur = order.firstIndex(of: selected) ?? 0
        selected = order[max(0, min(order.count - 1, cur + delta))]
        highlightSelected()
        table.scrollToRow(at: selected, at: .none, animated: true)
    }
    func openSelected() {
        guard isValid(selected) else { return }
        onSelect?(sections[selected.section].rows[selected.row])
    }

    private var flatIndexPaths: [IndexPath] {
        var out: [IndexPath] = []
        for (s, sec) in sections.enumerated() { for r in sec.rows.indices { out.append(IndexPath(row: r, section: s)) } }
        return out
    }
    private func isValid(_ ip: IndexPath) -> Bool { ip.section < sections.count && ip.row < sections[ip.section].rows.count }
    private func clampSelection() {
        if !isValid(selected) { selected = flatIndexPaths.first ?? IndexPath(row: 0, section: 0) }
        highlightSelected()
    }
    private func highlightSelected() {
        for ip in table.indexPathsForVisibleRows ?? [] {
            (table.cellForRow(at: ip) as? DeckProjectCell)?.setKeyFocused(ip == selected)
        }
    }

    // MARK: - DataSource / Delegate
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].rows.count }

    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "cell", for: ip) as! DeckProjectCell
        cell.configure(sections[ip.section].rows[ip.row])
        cell.setKeyFocused(ip == selected)
        return cell
    }
    func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? {
        let sec = sections[s]
        let proxy = sec.proxy.isEmpty ? "" : "  ·  🔒 \(sec.proxy)"
        return sec.hostName + "  ·  " + sec.addr + proxy + (sec.up ? "" : "  ·  离线")
    }
    func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        selected = ip; highlightSelected()
        onSelect?(sections[ip.section].rows[ip.row])
    }
}

/// project cell:SF Symbol 图标 + 名称 + 「类型 · 时长」副标题 + 右侧系统色状态徽章(色点 + 文案)/ 加载转圈
/// + disclosure 指示。整体走苹果原生 settings/list 风格。
final class DeckProjectCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let subLabel = UILabel()
    private let dot = UIView()
    private let stateLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let badgeColumn = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        backgroundColor = .secondarySystemGroupedBackground

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.textColor = .label
        subLabel.font = .preferredFont(forTextStyle: .footnote)
        subLabel.textColor = .secondaryLabel
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 4
        stateLabel.font = .preferredFont(forTextStyle: .caption1)

        let textCol = UIStackView(arrangedSubviews: [nameLabel, subLabel])
        textCol.axis = .vertical; textCol.spacing = 2
        let badge = UIStackView(arrangedSubviews: [dot, stateLabel])
        badge.axis = .horizontal; badge.spacing = 5; badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeColumn.translatesAutoresizingMaskIntoConstraints = false
        badgeColumn.addSubview(badge)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        badgeColumn.addSubview(spinner)
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])

        // 固定宽状态列:圆点钉在列首,3/4 字符状态的小圆点保持同一 x。
        NSLayoutConstraint.activate([
            badgeColumn.widthAnchor.constraint(equalToConstant: 80),
            badgeColumn.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            badge.leadingAnchor.constraint(equalTo: badgeColumn.leadingAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: badgeColumn.trailingAnchor),
            badge.centerYAnchor.constraint(equalTo: badgeColumn.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: badgeColumn.leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: badgeColumn.centerYAnchor),
        ])

        // spacer 撑开 → 固定宽状态列靠右。
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconView, textCol, spacer, badgeColumn])
        row.axis = .horizontal; row.spacing = 12; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        iv.setContentHuggingPriority(.required, for: .horizontal)
        return iv
    }()

    func configure(_ r: DeckRow) {
        iconView.image = UIImage(systemName: Self.symbol(r.type))
        iconView.tintColor = Self.tint(r.type)
        nameLabel.text = r.name
        let age = Self.ageText(r.since)
        subLabel.text = Self.typeLabel(r.type) + (age.isEmpty ? "" : "  ·  \(age)")
        if r.loading {
            spinner.startAnimating(); spinner.isHidden = false
            dot.isHidden = true; stateLabel.isHidden = true
        } else {
            spinner.stopAnimating(); spinner.isHidden = true
            let (color, label) = Self.badge(r.state)
            dot.isHidden = (label == nil); stateLabel.isHidden = (label == nil)
            dot.backgroundColor = color; stateLabel.text = label; stateLabel.textColor = color
        }
    }

    /// 物理键导航高亮:蓝色 tint(浅/深色都可见;tertiarySystemGroupedBackground 在浅色下≈分组灰,看不出)。
    func setKeyFocused(_ on: Bool) {
        backgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.18) : .secondarySystemGroupedBackground
    }

    // MARK: - 类型 → SF Symbol / 系统色
    private static func symbol(_ t: ProjectType) -> String {
        switch t {
        case .claude:  return "sparkles"
        case .codex:   return "chevron.left.forwardslash.chevron.right"
        case .agent:   return "cpu"
        case .maestro: return "command"
        case .ssh:     return "terminal"
        }
    }
    private static func tint(_ t: ProjectType) -> UIColor {
        switch t {
        case .claude:  return .systemPurple
        case .codex:   return .systemGreen
        case .agent:   return .systemTeal
        case .maestro: return .systemIndigo
        case .ssh:     return .systemGray
        }
    }
    private static func typeLabel(_ t: ProjectType) -> String {
        switch t { case .claude: return "Claude"; case .codex: return "Codex"; case .agent: return "Agent"; case .maestro: return "Maestro"; case .ssh: return "SSH" }
    }
    /// 状态徽章:(系统色, 文案)。文案 nil = 不显示(unknown)。
    private static func badge(_ state: String?) -> (UIColor, String?) {
        switch state {
        case "working":          return (.systemGreen, "工作中")
        case "waiting":          return (.systemOrange, "等待反馈")
        case "needs-permission": return (.systemRed, "待授权")
        case "disconnected":     return (.systemGray, "已断开")
        default:                 return (.systemGray, nil)
        }
    }
    private static func ageText(_ since: Int) -> String {
        guard since > 0 else { return "" }
        let secs = Int(Date().timeIntervalSince1970) - since
        guard secs >= 0 else { return "" }
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs/60)m" }
        if secs < 86400 { return "\(secs/3600)h" }
        return "\(secs/86400)d"
    }
}
