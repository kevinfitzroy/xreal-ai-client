import UIKit

/// 群控 **Home** 页(四页布局最左侧 dashboard;SPEC §14 舰队巡检的展示面)。
///
/// 当前是 **骨架**:§14 的语义分诊后端(读 status.json 闸门 → capture-pane → DeepSeek 判 →
/// 跨 host 聚合)尚未接入。在此之前,Home 直接消费已有的 hooks 状态(SPEC §3),按 §14.4
/// **降级形态**渲染:把所有 host 里 `waiting` / `needs-permission` 的 session 聚成一张「需要你
/// 关注」列表(无"为什么",那一句话原因留给 §14)。结构已就位,§14 落地后只需把 `why`/`urgency`
/// 灌进 `HomeRow` 即可。
///
/// overlay 面板范式同 `LogPanelView`(VC 用 slide 显隐)。
final class HomePanelView: UIView, UITableViewDataSource, UITableViewDelegate {

    /// 一个「需要你关注」的 agent(跨 host 聚合后的一行)。
    struct HomeRow {
        let host: String
        let session: String
        let name: String
        let type: ProjectType
        let state: String      // waiting | needs-permission
        let since: Int         // epoch 秒(0 = 无)
    }

    /// Home 视图模型(VC 从 hosts + statusByHost 算好喂进来)。
    struct Model {
        let attention: [HomeRow]   // 需要你关注(已按 since 升序 = 等得最久的在前)
        let working: Int           // 工作中的 agent 数
        let hostCount: Int
        let probing: Bool          // 仍在首轮探测(还没有任何状态)
    }

    var onSelect: ((HomeRow) -> Void)?

    private let headlineLabel = UILabel()
    private let subLabel = UILabel()
    private let noteLabel = UILabel()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()

    private var rows: [HomeRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGroupedBackground

        headlineLabel.font = .systemFont(ofSize: 30, weight: .bold)
        headlineLabel.textColor = .label
        headlineLabel.adjustsFontForContentSizeCategory = true

        subLabel.font = .preferredFont(forTextStyle: .subheadline)
        subLabel.textColor = .secondaryLabel
        subLabel.adjustsFontForContentSizeCategory = true

        noteLabel.font = .preferredFont(forTextStyle: .caption2)
        noteLabel.textColor = .tertiaryLabel
        noteLabel.numberOfLines = 0
        noteLabel.text = "语义分诊(SPEC §14)未接入 · 暂按运行状态聚合需要你处理的 agent"
        noteLabel.adjustsFontForContentSizeCategory = true

        let header = UIStackView(arrangedSubviews: [headlineLabel, subLabel, noteLabel])
        header.axis = .vertical
        header.spacing = 4
        header.setCustomSpacing(8, after: subLabel)
        header.translatesAutoresizingMaskIntoConstraints = false

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "home")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 60

        emptyLabel.font = .preferredFont(forTextStyle: .callout)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(table)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: table.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: table.centerYAnchor, constant: -20),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - render

    func render(_ m: Model) {
        rows = m.attention
        let n = m.attention.count
        if m.hostCount == 0 {
            headlineLabel.text = "暂无 host"
            subLabel.text = "AirDrop 一个 .xrhosts 配置导入"
            emptyLabel.isHidden = true
        } else if m.probing && n == 0 {
            headlineLabel.text = "正在巡检…"
            subLabel.text = "拉取各 host 状态中"
            emptyLabel.isHidden = true
        } else {
            headlineLabel.text = n == 0 ? "一切就绪" : "\(n) 个 agent 需要你"
            subLabel.text = "\(m.working) 工作中  ·  \(m.hostCount) host\(m.hostCount == 1 ? "" : "s")"
            emptyLabel.isHidden = (n != 0)
            emptyLabel.text = "暂无需要你处理的 agent\n所有 agent 在工作或空闲中"
        }
        table.reloadData()
    }

    // MARK: - UITableView

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        rows.isEmpty ? nil : "需要你关注"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "home", for: indexPath)
        let r = rows[indexPath.row]
        var c = UIListContentConfiguration.subtitleCell()
        c.text = r.name
        let age = Self.ageText(r.since)
        c.secondaryText = "\(r.host) · \(r.session)" + (age.isEmpty ? "" : "  ·  \(age)")
        c.secondaryTextProperties.color = .secondaryLabel
        c.image = UIImage(systemName: Self.stateSymbol(r.state))
        c.imageProperties.tintColor = Self.stateColor(r.state)
        c.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(rows[indexPath.row])
    }

    // MARK: - state → 视觉(对齐 DeckListView 的语义)

    private static func stateSymbol(_ state: String) -> String {
        switch state {
        case "needs-permission": return "exclamationmark.shield.fill"
        case "waiting":          return "questionmark.circle.fill"
        default:                 return "circle.fill"
        }
    }
    private static func stateColor(_ state: String) -> UIColor {
        switch state {
        case "needs-permission": return .systemRed
        case "waiting":          return .systemOrange
        default:                 return .systemGray
        }
    }
    private static func ageText(_ since: Int) -> String {
        guard since > 0 else { return "" }
        let secs = Int(Date().timeIntervalSince1970) - since
        guard secs >= 0 else { return "" }
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }
}
