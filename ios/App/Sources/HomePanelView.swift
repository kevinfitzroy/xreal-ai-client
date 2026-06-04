import UIKit

/// **Agent Station** 落地仪表盘(四页布局最左:logs ← home ← list → terminal;SPEC §14 展示面)。
///
/// 深色 console 风:顶部 brand wordmark + 大数字 hero(几个 agent 等你)+ 计数 pill(运行/离线)+
/// 「需要你关注」卡片(name + 一句话 why + host·session·时长 + 紧急度配色)。数据来自 §14 巡检 digest;
/// 未巡检/无判官时 hooks 降级(§14.4)。overlay 面板范式同 LogPanelView(VC 用 slide 显隐)。
final class HomePanelView: UIView, UITableViewDataSource, UITableViewDelegate {

    /// 一个「需要你关注」的 agent(跨 host 聚合后的一行)。
    struct HomeRow {
        let host: String
        let session: String
        let name: String
        let type: ProjectType
        let state: String      // waiting | needs-permission
        let since: Int         // epoch 秒(0 = 无)
        let why: String        // §14 判官给的一句话原因;"" = 无(未巡检/降级)
        let urgency: String    // high | normal
    }

    /// Home 视图模型(VC 从 hosts + statusByHost 算好喂进来)。
    struct Model {
        let attention: [HomeRow]
        let working: Int
        let offline: Int
        let hostCount: Int
        let probing: Bool
        let judgeActive: Bool
    }

    var onSelect: ((HomeRow) -> Void)?

    private let wordmark = UILabel()
    private let heroNumber = UILabel()
    private let heroCaption = UILabel()
    private let pillStack = UIStackView()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private let footLabel = UILabel()

    private var rows: [HomeRow] = []
    private var footText = ""

    private static let bg = UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1)   // 近黑 console 底
    private static let card = UIColor(red: 0.094, green: 0.102, blue: 0.125, alpha: 1)  // 卡片底
    private static let amber = UIColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1)
    private static let red = UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)
    private static let green = UIColor(red: 0.36, green: 0.86, blue: 0.55, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        backgroundColor = Self.bg

        wordmark.attributedText = NSAttributedString(string: "AGENT STATION", attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .heavy),
            .kern: 3.0,
            .foregroundColor: UIColor(white: 1, alpha: 0.34),
        ])

        heroNumber.font = .systemFont(ofSize: 60, weight: .bold)
        heroNumber.textColor = Self.amber
        heroNumber.adjustsFontForContentSizeCategory = false

        heroCaption.font = .systemFont(ofSize: 16, weight: .medium)
        heroCaption.textColor = UIColor(white: 1, alpha: 0.62)
        heroCaption.numberOfLines = 0

        pillStack.axis = .horizontal
        pillStack.spacing = 8
        pillStack.alignment = .center

        let head = UIStackView(arrangedSubviews: [wordmark, heroNumber, heroCaption, pillStack])
        head.axis = .vertical
        head.alignment = .fill
        head.spacing = 2
        head.setCustomSpacing(8, after: wordmark)
        head.setCustomSpacing(2, after: heroNumber)
        head.setCustomSpacing(14, after: heroCaption)
        head.translatesAutoresizingMaskIntoConstraints = false

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.register(HomeCell.self, forCellReuseIdentifier: "home")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 72
        table.contentInset = UIEdgeInsets(top: 2, left: 0, bottom: 28, right: 0)

        emptyLabel.font = .systemFont(ofSize: 15, weight: .regular)
        emptyLabel.textColor = UIColor(white: 1, alpha: 0.45)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        footLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footLabel.textColor = UIColor(white: 1, alpha: 0.30)
        footLabel.numberOfLines = 0
        footLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(head)
        addSubview(table)
        addSubview(emptyLabel)
        addSubview(footLabel)

        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 18),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),

            table.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 60),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            footLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            footLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
            footLabel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - render

    func render(_ m: Model) {
        rows = m.attention
        let n = m.attention.count

        if m.hostCount == 0 {
            heroNumber.isHidden = true
            heroCaption.text = "暂无 host\nAirDrop 一个 .xrhosts 配置导入"
            pillStack.isHidden = true
            emptyLabel.isHidden = true
        } else if m.probing && n == 0 {
            heroNumber.isHidden = true
            heroCaption.text = "正在巡检舰队…"
            pillStack.isHidden = true
            emptyLabel.isHidden = true
        } else if n == 0 {
            heroNumber.isHidden = false
            heroNumber.text = "✓"
            heroNumber.textColor = Self.green
            heroCaption.text = "全部就绪 · 没有 agent 在等你"
            rebuildPills(working: m.working, offline: m.offline)
            pillStack.isHidden = (m.working == 0 && m.offline == 0)
            emptyLabel.isHidden = true
        } else {
            heroNumber.isHidden = false
            heroNumber.text = "\(n)"
            heroNumber.textColor = m.attention.contains { $0.urgency == "high" } ? Self.red : Self.amber
            heroCaption.text = "个 agent 等你处理"
            rebuildPills(working: m.working, offline: m.offline)
            pillStack.isHidden = (m.working == 0 && m.offline == 0)
            emptyLabel.isHidden = true
        }
        emptyLabel.text = ""

        footText = m.hostCount == 0 ? ""
            : (m.judgeActive ? "DeepSeek V4 Pro · 实时分诊" : "未配判官 · 按运行状态聚合(配 DeepSeek key 启用语义分诊)")
        footLabel.text = footText
        footLabel.isHidden = footText.isEmpty

        table.reloadData()
    }

    private func rebuildPills(working: Int, offline: Int) {
        pillStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if working > 0 { pillStack.addArrangedSubview(makeChip("\(working) 运行", color: Self.green)) }
        if offline > 0 { pillStack.addArrangedSubview(makeChip("\(offline) 离线", color: UIColor(white: 1, alpha: 0.5))) }
        pillStack.addArrangedSubview(UIView())   // 末尾弹性占位 → 胶囊靠左
    }

    private func makeChip(_ text: String, color: UIColor) -> UIView {
        let l = Chip()
        let dot = NSTextAttachment()
        l.attributedText = NSAttributedString(string: "● " + text, attributes: [
            .font: UIFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: color,
        ])
        _ = dot
        l.backgroundColor = color.withAlphaComponent(0.14)
        l.layer.cornerRadius = 13
        l.layer.borderWidth = 1
        l.layer.borderColor = color.withAlphaComponent(0.22).cgColor
        l.clipsToBounds = true
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    // MARK: - UITableView

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        rows.isEmpty ? nil : "需要你关注"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "home", for: indexPath) as! HomeCell
        cell.configure(rows[indexPath.row], cardColor: Self.card, ageText: Self.ageText)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(rows[indexPath.row])
    }

    static func ageText(_ since: Int) -> String {
        guard since > 0 else { return "" }
        let secs = Int(Date().timeIntervalSince1970) - since
        guard secs >= 0 else { return "" }
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }
}

// MARK: - 关注卡片(深色 + 左侧紧急度色条 + 等宽 meta)

private final class HomeCell: UITableViewCell {
    private let accent = UIView()
    private let nameLabel = UILabel()
    private let whyLabel = UILabel()
    private let metaLabel = UILabel()

    private static let red = UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)
    private static let amber = UIColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let sel = UIView(); sel.backgroundColor = UIColor(white: 1, alpha: 0.06); selectedBackgroundView = sel

        accent.layer.cornerRadius = 1.5
        accent.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = .white
        whyLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        whyLabel.textColor = UIColor(white: 1, alpha: 0.66)
        whyLabel.numberOfLines = 2
        metaLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = UIColor(white: 1, alpha: 0.34)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor(white: 1, alpha: 0.26)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [nameLabel, whyLabel, metaLabel])
        text.axis = .vertical
        text.spacing = 3
        text.setCustomSpacing(5, after: whyLabel)
        text.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(accent)
        contentView.addSubview(text)
        contentView.addSubview(chevron)
        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            accent.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            accent.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            accent.widthAnchor.constraint(equalToConstant: 3),

            text.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 13),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            chevron.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 10),
            chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: HomePanelView.HomeRow, cardColor: UIColor, ageText: (Int) -> String) {
        let hi = r.urgency == "high" || r.state == "needs-permission"
        accent.backgroundColor = hi ? Self.red : Self.amber
        nameLabel.text = r.name
        whyLabel.text = r.why.isEmpty ? (r.state == "needs-permission" ? "等待权限确认" : "等待你的反馈") : r.why
        let age = ageText(r.since)
        metaLabel.text = "\(r.host) · \(r.session)" + (age.isEmpty ? "" : "  ·  \(age)")
        // 卡片底:insetGrouped 默认卡用得上;这里直接给 contentView 一个深色卡背景。
        backgroundColor = cardColor
    }
}

/// 紧凑内边距的胶囊标签(pill 用)。
private final class Chip: UILabel {
    private let inset = UIEdgeInsets(top: 5, left: 11, bottom: 5, right: 11)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}
