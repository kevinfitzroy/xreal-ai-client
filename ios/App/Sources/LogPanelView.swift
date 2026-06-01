import UIKit

final class LogPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onClose: (() -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let versionLabel = UILabel()
    private let filter = UISegmentedControl(items: ["All", "Debug", "Info", "Warn", "Error"])
    private let closeButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private var entries: [AgentLogEntry] = []
    private var visibleEntries: [AgentLogEntry] = []
    private var logObs: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0x1f / 255.0, green: 0x20 / 255.0, blue: 0x22 / 255.0, alpha: 1)

        titleLabel.text = "Logs"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white

        versionLabel.text = AppVersion.display
        versionLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = UIColor(white: 1, alpha: 0.42)
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        clearButton.setImage(UIImage(systemName: "trash"), for: .normal)
        clearButton.tintColor = UIColor(white: 1, alpha: 0.78)
        clearButton.addAction(UIAction { _ in AgentLog.shared.clear() }, for: .touchUpInside)

        filter.selectedSegmentIndex = 0
        filter.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.18)
        filter.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        filter.setTitleTextAttributes([.foregroundColor: UIColor(white: 1, alpha: 0.72)], for: .normal)
        filter.addAction(UIAction { [weak self] _ in self?.reloadFromStore(scrollToBottom: false) }, for: .valueChanged)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorColor = UIColor(white: 1, alpha: 0.08)
        table.dataSource = self
        table.delegate = self
        table.register(LogEntryCell.self, forCellReuseIdentifier: "log")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 54

        let topBar = UIStackView(arrangedSubviews: [titleLabel, UIView(), versionLabel, clearButton, closeButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 10
        topBar.translatesAutoresizingMaskIntoConstraints = false
        filter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(filter)
        addSubview(table)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 38),
            closeButton.heightAnchor.constraint(equalToConstant: 38),
            clearButton.widthAnchor.constraint(equalToConstant: 38),
            clearButton.heightAnchor.constraint(equalToConstant: 38),

            topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            filter.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            table.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 10),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        logObs = NotificationCenter.default.addObserver(
            forName: .agentLogDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadFromStore(scrollToBottom: true) }
        reloadFromStore(scrollToBottom: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func refresh() {
        reloadFromStore(scrollToBottom: true)
    }

    private func reloadFromStore(scrollToBottom: Bool) {
        entries = AgentLog.shared.snapshot()
        visibleEntries = entries.filter { e in
            switch filter.selectedSegmentIndex {
            case 1: return e.level == .debug
            case 2: return e.level == .info
            case 3: return e.level == .warn
            case 4: return e.level == .error
            default: return true
            }
        }
        table.reloadData()
        guard scrollToBottom, !visibleEntries.isEmpty else { return }
        table.scrollToRow(at: IndexPath(row: visibleEntries.count - 1, section: 0), at: .bottom, animated: false)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleEntries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "log", for: indexPath) as! LogEntryCell
        cell.configure(visibleEntries[indexPath.row])
        return cell
    }

    deinit {
        if let logObs { NotificationCenter.default.removeObserver(logObs) }
    }
}

private final class LogEntryCell: UITableViewCell {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private let timeLabel = UILabel()
    private let levelLabel = LogPillLabel()
    private let categoryLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = UIColor(white: 1, alpha: 0.46)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        levelLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        levelLabel.textColor = .white
        levelLabel.layer.cornerRadius = 5
        levelLabel.clipsToBounds = true
        levelLabel.textAlignment = .center
        levelLabel.setContentHuggingPriority(.required, for: .horizontal)

        categoryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        categoryLabel.textColor = UIColor(white: 1, alpha: 0.68)

        messageLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = UIColor(white: 1, alpha: 0.88)
        messageLabel.numberOfLines = 0

        let top = UIStackView(arrangedSubviews: [timeLabel, levelLabel, categoryLabel])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = 8

        let stack = UIStackView(arrangedSubviews: [top, messageLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ entry: AgentLogEntry) {
        timeLabel.text = Self.timeFormatter.string(from: entry.date)
        levelLabel.text = " \(entry.level.title) "
        levelLabel.backgroundColor = Self.color(entry.level).withAlphaComponent(0.9)
        categoryLabel.text = entry.category
        messageLabel.text = entry.message
    }

    private static func color(_ level: AgentLogLevel) -> UIColor {
        switch level {
        case .debug: return .systemGray
        case .info: return .systemBlue
        case .warn: return .systemOrange
        case .error: return .systemRed
        }
    }
}

private final class LogPillLabel: UILabel {
    private let inset = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}
