import UIKit

/// **Agent Station** 落地仪表盘(四页布局最左:logs ← home ← list → terminal;SPEC §14 展示面)。
///
/// 深色 console 风:顶部 brand wordmark + 大数字 hero(几个 agent 等你)+ 计数 pill(运行/离线)+
/// 「需要你关注」卡片(name + 一句话 why + host·session·时长 + 紧急度配色)。数据来自 §14 巡检 digest;
/// 未巡检/无判官时 hooks 降级(§14.4)。overlay 面板范式同 LogPanelView(VC 用 slide 显隐)。
final class HomePanelView: UIView, UITableViewDelegate {

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

    /// 一个录音转写任务行(收件箱里的录音,独立于任何 host)。
    struct RecordingRow {
        let id: String          // 文件名,增量 diff 用
        let name: String
        let state: String       // received | processing | done | failed
        let detail: String      // 子状态 / 失败原因(待转译 / 待投递 / 投递中 / 识别失败…)
        let since: Int          // 收到时间 epoch 秒
    }

    /// Home 视图模型(VC 从 hosts + statusByHost + MeetingStore 算好喂进来)。
    /// 录音拆两级(issue #23):`pending` 始终展开;`processed` 默认折叠(点 header 展开)。
    struct Model {
        let attention: [HomeRow]
        let recordingsPending: [RecordingRow]
        let recordingsProcessed: [RecordingRow]
        let working: Int
        let offline: Int
        let hostCount: Int
        let probing: Bool
        let judgeActive: Bool
    }

    var onSelect: ((HomeRow) -> Void)?
    var onSelectRecording: ((RecordingRow) -> Void)?

    private let wordmark = UILabel()
    private let heroNumber = UILabel()
    private let heroCaption = UILabel()
    private let pillStack = UIStackView()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private let footLabel = UILabel()

    private var rows: [HomeRow] = []
    private var recPending: [RecordingRow] = []
    private var recProcessed: [RecordingRow] = []
    private var processedExpanded = false   // 「已处理」默认折叠(issue #23)
    private var footText = ""

    // diffable:折叠/展开走 snapshot 动画(协调高度变化 → 丝滑)。
    private var dataSource: HomeDataSource!
    private var attentionByID: [String: HomeRow] = [:]   // item id → 原始结构(cellProvider 查回)
    private var recByID: [String: RecordingRow] = [:]
    private func aid(_ r: HomeRow) -> String { "\(r.host)|\(r.session)|\(r.name)" }

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
        table.delegate = self
        table.register(HomeCell.self, forCellReuseIdentifier: "home")
        table.register(RecordingCell.self, forCellReuseIdentifier: "rec")
        table.register(ProcessedSectionHeader.self, forHeaderFooterViewReuseIdentifier: ProcessedSectionHeader.reuseID)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 72
        table.contentInset = UIEdgeInsets(top: 2, left: 0, bottom: 28, right: 0)

        dataSource = HomeDataSource(tableView: table) { [weak self] tv, indexPath, item in
            guard let self else { return UITableViewCell() }
            switch item {
            case .attention(let id):
                let cell = tv.dequeueReusableCell(withIdentifier: "home", for: indexPath) as! HomeCell
                if let r = self.attentionByID[id] { cell.configure(r, cardColor: Self.card, ageText: Self.ageText) }
                return cell
            case .recording(let id):
                let cell = tv.dequeueReusableCell(withIdentifier: "rec", for: indexPath) as! RecordingCell
                if let r = self.recByID[id] { cell.configure(r, cardColor: Self.card) }
                return cell
            }
        }
        dataSource.defaultRowAnimation = .fade

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

        recPending = m.recordingsPending
        recProcessed = m.recordingsProcessed
        attentionByID = Dictionary(rows.map { (aid($0), $0) }, uniquingKeysWith: { a, _ in a })
        recByID = Dictionary((recPending + recProcessed).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 数据刷新(轮询)不做动画,避免每次巡检都抖;折叠/展开才动画(toggleProcessed)。
        applySnapshot(animating: false)
    }

    /// 按当前数据 + 折叠态构建 snapshot。`.processed` section 永远在(只要有已处理录音),
    /// 折叠时不塞 item(只剩可点 header)→ 展开/收拢就是一次 item insert/delete 的协调动画。
    private func applySnapshot(animating: Bool) {
        var snap = NSDiffableDataSourceSnapshot<HSection, HItem>()
        // 防御性去重:diffable 撞重复 id 会崩。现有数据天然唯一(inbox 单目录文件名 + state 二分),
        // 这里只是兜底——万一上游 id 唯一性被破坏,顶多少显示一行,绝不崩。保序保留首次出现。
        var seen = Set<HItem>()
        func fresh(_ items: [HItem]) -> [HItem] { items.filter { seen.insert($0).inserted } }
        if !rows.isEmpty {
            snap.appendSections([.attention])
            snap.appendItems(fresh(rows.map { .attention(aid($0)) }), toSection: .attention)
        }
        if !recPending.isEmpty {
            snap.appendSections([.pending])
            snap.appendItems(fresh(recPending.map { .recording($0.id) }), toSection: .pending)
        }
        if !recProcessed.isEmpty {
            snap.appendSections([.processed])
            if processedExpanded {
                snap.appendItems(fresh(recProcessed.map { .recording($0.id) }), toSection: .processed)
            }
        }
        // 数据刷新(非动画):diffable 只按 id 增删、不重配同 id 的 cell → 录音状态/关注卡内容(状态/why/时长)
        // 会 stale。强制重配仍存在的 item(只重配旧快照里已有的,避免对新 item 误调)。折叠动画(toggle)
        // 不重配,保持纯 insert/delete 协调。
        if !animating {
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            let reconf = snap.itemIdentifiers.filter(existing.contains)
            if !reconf.isEmpty { snap.reconfigureItems(reconf) }
        }
        dataSource.apply(snap, animatingDifferences: animating)
        // diffable apply 也不刷 section header → 「已处理 (N)」计数会 stale;数据刷新后手动刷可见的那个。
        if !animating,
           let s = snap.sectionIdentifiers.firstIndex(of: .processed),
           let h = table.headerView(forSection: s) as? ProcessedSectionHeader {
            h.configure(count: recProcessed.count, expanded: processedExpanded)
        }
    }

    private func sectionKind(at index: Int) -> HSection? {
        let secs = dataSource.snapshot().sectionIdentifiers
        return index < secs.count ? secs[index] : nil
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

    // MARK: - UITableViewDelegate(cell/section 数据由 diffable dataSource 提供;这里只管 header 视图/高度/选中)

    /// 「已处理」用自定义可折叠 header(Files/Notes 折叠文件夹范式):箭头在前(展开旋转)+ 标题 + 右侧计数,
    /// 整行可点带按压高亮、上下留白。其它 section 用系统默认(标题由 HomeDataSource 给)。
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sectionKind(at: section) == .processed else { return nil }
        let h = tableView.dequeueReusableHeaderFooterView(withIdentifier: ProcessedSectionHeader.reuseID) as! ProcessedSectionHeader
        h.configure(count: recProcessed.count, expanded: processedExpanded)
        h.onTap = { [weak self] in self?.toggleProcessed() }
        return h
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sectionKind(at: section) == .processed ? 60 : UITableView.automaticDimension
    }
    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        sectionKind(at: section) == .processed ? 60 : 28
    }

    @objc private func toggleProcessed() {
        processedExpanded.toggle()
        // 箭头弹簧旋转(立即,跟手);行展开/收拢走 snapshot 协调动画。
        if let s = dataSource.snapshot().sectionIdentifiers.firstIndex(of: .processed),
           let h = table.headerView(forSection: s) as? ProcessedSectionHeader {
            h.setExpanded(processedExpanded, animated: true)
        }
        applySnapshot(animating: true)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .attention(let id):  if let r = attentionByID[id] { onSelect?(r) }
        case .recording(let id):  if let r = recByID[id] { onSelectRecording?(r) }
        }
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

// MARK: - diffable 身份 + dataSource(snapshot 驱动折叠动画)

/// section 标识。`.processed` 用自定义可点 header,其余系统默认标题(见 HomeDataSource)。
private enum HSection: Hashable { case attention, pending, processed }

/// item 标识(diffable 要 Hashable 且唯一)。attention 用 host|session|name;recording 用文件名 id。
private enum HItem: Hashable {
    case attention(String)
    case recording(String)
}

/// 子类化只为给 `.attention`/`.pending` 提供系统默认 header 标题(diffable dataSource 不走 delegate 的
/// titleForHeaderInSection)。`.processed` 返回 nil → 由 viewForHeaderInSection 出自定义可折叠 header。
private final class HomeDataSource: UITableViewDiffableDataSource<HSection, HItem> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let secs = snapshot().sectionIdentifiers
        guard section < secs.count else { return nil }
        switch secs[section] {
        case .attention: return "需要你关注"
        case .pending:   return "待处理录音"
        case .processed: return nil
        }
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

// MARK: - 录音转写卡片(波形图标 + 名 + 状态;转写中转圈)

private final class RecordingCell: UITableViewCell {
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private let stateLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private static let amber = UIColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1)
    private static let green = UIColor(red: 0.36, green: 0.86, blue: 0.55, alpha: 1)
    private static let red = UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let sel = UIView(); sel.backgroundColor = UIColor(white: 1, alpha: 0.06); selectedBackgroundView = sel

        icon.image = UIImage(systemName: "waveform")
        icon.tintColor = UIColor(white: 1, alpha: 0.62)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingMiddle
        // 时间醒目:同地点录音默认标题(地理位置)常常一样,时间才是主要区分点。
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        timeLabel.textColor = UIColor(white: 1, alpha: 0.55)
        stateLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        spinner.hidesWhenStopped = true

        let textCol = UIStackView(arrangedSubviews: [nameLabel, timeLabel])
        textCol.axis = .vertical; textCol.spacing = 2

        let row = UIStackView(arrangedSubviews: [icon, textCol, UIView(), spinner, stateLabel])
        row.axis = .horizontal; row.spacing = 10; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: HomePanelView.RecordingRow, cardColor: UIColor) {
        backgroundColor = cardColor
        nameLabel.text = r.name
        timeLabel.text = Self.timeText(r.since)
        // 子状态文案由 store 给(待转译/待投递/投递中/识别失败…),这里只配色 + 转圈。
        let text = r.detail.isEmpty ? r.state : r.detail
        switch r.state {
        case "processing":
            spinner.startAnimating()
            stateLabel.text = text; stateLabel.textColor = Self.amber
        case "done":
            spinner.stopAnimating()
            stateLabel.text = "已处理"; stateLabel.textColor = Self.green
        case "failed":
            spinner.stopAnimating()
            stateLabel.text = "\(text)·重试"; stateLabel.textColor = Self.red
        default:   // received(待转译 / 待投递)
            spinner.stopAnimating()
            stateLabel.text = text
            stateLabel.textColor = r.detail == "待投递" ? Self.amber : UIColor(white: 1, alpha: 0.5)
        }
    }

    /// 绝对时间,区分同标题录音:今天/昨天 HH:mm;更早 M月d日 HH:mm(跨年带年份)。
    private static func timeText(_ since: Int) -> String {
        guard since > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(since))
        let cal = Calendar.current
        let tf = DateFormatter(); tf.locale = Locale(identifier: "zh_CN"); tf.dateFormat = "HH:mm"
        let hm = tf.string(from: date)
        if cal.isDateInToday(date) { return "今天 \(hm)" }
        if cal.isDateInYesterday(date) { return "昨天 \(hm)" }
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return df.string(from: date)
    }
}

/// 「已处理」可折叠 section header(Files/Notes 折叠文件夹范式):箭头(展开→down)+ 标题 + 右侧计数。
/// 整行是一个 UIControl → 真实点击区 + 按压圆角高亮,上下留白与下方卡片拉开距离。
private final class ProcessedSectionHeader: UITableViewHeaderFooterView {
    static let reuseID = "processedHeader"
    var onTap: (() -> Void)?

    private let hit = UIControl()
    private let chevron = UIImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)

        chevron.tintColor = UIColor(white: 1, alpha: 0.55)
        chevron.contentMode = .center
        chevron.image = UIImage(systemName: "chevron.right")   // 固定图,展开靠 transform 旋转(丝滑)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = "已处理"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = UIColor(white: 1, alpha: 0.78)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        countLabel.textColor = UIColor(white: 1, alpha: 0.4)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [chevron, titleLabel, UIView(), countLabel])
        row.axis = .horizontal; row.spacing = 8; row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false

        hit.translatesAutoresizingMaskIntoConstraints = false
        hit.layer.cornerRadius = 10
        hit.addSubview(row)
        hit.addTarget(self, action: #selector(fire), for: .touchUpInside)
        hit.addTarget(self, action: #selector(highlightOn), for: [.touchDown, .touchDragEnter])
        hit.addTarget(self, action: #selector(highlightOff), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        contentView.addSubview(hit)

        NSLayoutConstraint.activate([
            hit.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            hit.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            hit.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            hit.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: hit.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: hit.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: hit.topAnchor),
            row.bottomAnchor.constraint(equalTo: hit.bottomAnchor),
            hit.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            chevron.widthAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, expanded: Bool) {
        countLabel.text = "\(count)"
        setExpanded(expanded, animated: false)
    }

    /// 箭头旋转:展开 = chevron.right 顺时针转 90° → 指下;收起回正。带 = 弹簧动画。
    func setExpanded(_ expanded: Bool, animated: Bool) {
        let t: CGAffineTransform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        guard animated else { chevron.transform = t; return }
        UIView.animate(withDuration: 0.34, delay: 0,
                       usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            self.chevron.transform = t
        }
    }
    @objc private func fire() { onTap?() }
    @objc private func highlightOn() {
        UIView.animate(withDuration: 0.08) { self.hit.backgroundColor = UIColor(white: 1, alpha: 0.09) }
    }
    @objc private func highlightOff() {
        UIView.animate(withDuration: 0.18) { self.hit.backgroundColor = .clear }
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
