import UIKit
import GameController
import AVFoundation
import SwiftTerm
import Network

/// Core-loop controller. Mirrors Android's MainActivity:
///   hosts.json → Agent Station list → openProject → SSH(ed25519) PTY terminal → back.
///
/// **架构(2026-06 iOS 全面原生化)**:列表态 = **原生 `DeckListView`(UITableView)**,标准 iPhone 体验
/// (点 cell 进 project、下拉刷新、滑动、状态栏可见);终端态 = **原生 SwiftTerm `TerminalView`**(沉浸式全屏)。
/// WKWebView/index.html 已退出 iOS(只留 Android)。两个 view 叠放,按 view_ 显隐切换;
/// 物理键(8BitDo)经 pressesBegan:列表态 → deckList 选择/打开;终端态 → SwiftTerm 直接编码;F1/F2 拦截。
final class TerminalViewController: UIViewController, TerminalViewDelegate, TerminalHostKeyHandler, UIGestureRecognizerDelegate, TerminalScrollRailDelegate {

    // 沉浸式全屏**只在终端态**(AR 眼镜):隐藏状态栏 + home indicator。列表态恢复标准 iOS chrome。
    override var prefersStatusBarHidden: Bool { view_ == .terminal }
    override var prefersHomeIndicatorAutoHidden: Bool { view_ == .terminal }

    // 原生列表(替代 WKWebView/index.html)。
    private let deckList = DeckListView(frame: .zero)
    // 群控 Home(四页布局最左:logs ← home ← list → terminal;SPEC §14 展示面)。落地页。
    private let homePanel = HomePanelView(frame: .zero)
    // 列表页右滑进入的运行日志容器。
    private let logPanel = LogPanelView(frame: .zero)
    // 原生终端(SwiftTerm):终端态渲染 + 键盘;列表态隐藏。
    private var term: TerminalHostView!
    // 语音预览浮层(原生)。
    private let voiceOverlay = VoiceOverlayView()
    private let terminalBottomCover = UIView()
    private let channelStrip = UILabel()
    // 终端右缘无极拨轮 + 底部"新消息"药丸(滚上去看历史时,新输出不弹底,点药丸跳回最新)。
    private let scrollRail = TerminalScrollRail(frame: .zero)
    private let newMsgPill = UIView()
    private let newMsgLabel = UILabel()
    private var newMsgCount = 0
    private var lastHandoffAt: CFTimeInterval = 0
    private static let handoffMinInterval: CFTimeInterval = 0.12   // tmux 深历史接力限速(每拍一次 SSH)
    // 触屏虚拟键盘(原生),无硬件键盘时挂为终端的 inputAccessoryView。
    private var keyBar: TerminalKeyBar!
    // 按键震动(VC 主窗口上下文触发;keybar 在键盘窗口里触发观测不到震动)。
    private let keyHaptic = UIImpactFeedbackGenerator(style: .light)
    // 键盘(触屏 vkey)避让:终端高度缩到键盘顶之上。
    private var keyboardOverlap: CGFloat = 0
    private var forcedKeyboardOverlap: CGFloat?
    private var cachedKeyBarOverlap: CGFloat = 0
    private var cachedKeyBarWidth: CGFloat = 0
    private var lastDelWordHapticAt: CFTimeInterval = 0
    private var activeProjectType: ProjectType?
    private var activeHostConfig: HostConfig?
    private var activeViaConfig: HostConfig?
    private var activeSessionName: String?
    private var voiceArmed = false   // 语音长按中,手指上滑到 overlay = armed(松手转录音)
    private var recordingHUD: UIView?   // 录音转写期间的全屏阻塞 HUD(防误触)
    /// 自认为处于 tmux copy-mode(翻页/复制)。单一状态源:同时驱动语音警告 + ESC 键安全态配色 + 轮询确认。
    /// 设 true(进 copy-mode)→ ESC 变安全绿 + 起轮询;设 false(退出)→ 复原 + 停轮询。所有现有赋值点自动联动。
    private var tmuxModeLikely = false {
        didSet {
            guard oldValue != tmuxModeLikely else { return }
            keyBar?.escCopyModeSafe = tmuxModeLikely
            if tmuxModeLikely { startCopyModePoll() } else { stopCopyModePoll() }
        }
    }
    private var copyModePollTimer: Timer?
    private var suppressTermAccessory = false
    private var kbFrameObs: NSObjectProtocol?
    private var kbHideObs: NSObjectProtocol?
    private var edgeDragging = false
    private weak var termVoicePress: UILongPressGestureRecognizer?
    private weak var termReturnPan: UIPanGestureRecognizer?
    private weak var listResumePan: UIPanGestureRecognizer?
    private weak var listLogPan: UIPanGestureRecognizer?   // 现管 home↔logs(原 list↔logs)
    private weak var homePan: UIPanGestureRecognizer?      // list↔home
    private var logDragging = false
    private var homeDragging = false

    private enum ViewState { case home, list, terminal, logs }
    private enum TerminalTouchZone { case voice, none }
    private enum ChannelStripState { case hidden, checking, suspect, reconnecting, disconnected }
    private var view_ = ViewState.list
    private static let noEchoGraceSeconds: TimeInterval = 3.8

    // Active PTY session(终端态活动;**列表态保活中也非 nil**,见 iOS.7)。
    private var ssh: SSHSession?
    private var openSeq = 0      // fast open→back→open mustn't bind a stale PTY
    private var sessionGen = 0   // late output chunk from a closed session must not paint a new one
    private var outputSeq = 0
    private var echoWatchWork: DispatchWorkItem?
    private var channelStripState = ChannelStripState.hidden
    private var autoReconnectWork: DispatchWorkItem?
    private var autoReconnectAttempts = 0
    // iOS.7 最近终端保活:backToList 不关 ssh,保留 SwiftTerm 绘制 + 后台继续喂输出;超时才真关。
    // 开同一 project / 列表右缘滑 = 滑回(已连接则瞬间,连接中则回到连接页);开不同 project = 关旧连新。
    // warm* = 当前/保活终端身份。
    private var warmHost: String?
    private var warmSession: String?
    private var keepWarmWork: DispatchWorkItem?
    private static let keepWarmSeconds: Double = 90   // 短时间保活;超时关 client(tmux session 服务端仍在)
    private static let maxReconnectAttempts = 5              // 指数退避:1s→2s→4s→8s→16s,总约31s
    private static let terminalBackgroundColor = UIColor(red: 0x28 / 255.0, green: 0x29 / 255.0, blue: 0x2b / 255.0, alpha: 1)
    private static let terminalForegroundColor = UIColor(red: 0xd6 / 255.0, green: 0xd8 / 255.0, blue: 0xdc / 255.0, alpha: 1)
    private static let channelStripHeight: CGFloat = 18
    private static let listResumeStartFraction: CGFloat = 0.25   // 右侧 75% 区域都可左滑回最近终端
    private static let shiftUpBytes: [UInt8] = [0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41]
    private static let shiftDownBytes: [UInt8] = [0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x42]
    private static let copyModeVoiceWarning = "当前仍在 tmux 翻页/复制模式，语音文字不会进入终端。请先按 Esc 退出后再语音输入。"

    private var hosts: [HostConfig] = []
    // Live status (SPEC §3). reachable == nil = not yet probed.
    private var statusByHost: [String: [String: SessionState]] = [:]
    private var reachable: Set<String>? = nil
    private var probedHosts: Set<String> = []   // hosts whose probe landed this round (incremental loading)
    private var fetchGen = 0                     // race guard: overlapping refreshManifests

    private var kbConnectObs: NSObjectProtocol?
    private var kbDisconnectObs: NSObjectProtocol?
    private var foregroundObs: NSObjectProtocol?
    private var meetingObs: NSObjectProtocol?

    // 语音输入(Android VoiceDaemon 的对应)。
    private var voice: VoiceController!
    private var micRequested = false
    private var voiceKeyHeld = false

    // 舰队巡检分诊(SPEC §14)。Home/列表态周期跑一轮:fetch+capture-pane → DeepSeek 判 → 聚合喂 Home。
    private let fleetTriage = FleetTriage()
    private var triageItems: [TriageItem]? = nil   // 最近一轮 digest;nil = 尚未巡检(Home 用 hooks 降级)
    private var triageTimer: Timer?
    private static let triageIntervalSeconds: TimeInterval = 25
    private var lastNeedsYouKeys: Set<String> = []   // 上轮「需要你」的 host\u{1}session,用于检测"新出现"
    private var triageBaselineSet = false             // 首轮只建基线,不弹 banner(防启动刷屏)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = "Agent Station"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "slider.horizontal.3"),
            style: .plain, target: self, action: #selector(presentHostManager))

        // 原生列表:全屏(内容自动避让安全区/状态栏);终端态被 term 盖住。
        deckList.translatesAutoresizingMaskIntoConstraints = false
        deckList.onSelect = { [weak self] r in self?.onOpenProject(host: r.host, session: r.session, name: r.name, type: r.type.rawValue) }
        deckList.onRefresh = { [weak self] in self?.refreshManifests() }
        view.addSubview(deckList)
        NSLayoutConstraint.activate([
            deckList.topAnchor.constraint(equalTo: view.topAnchor),
            deckList.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            deckList.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            deckList.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 群控 Home:frame 布局(同 logPanel,由 layoutHomePanel 管);z 序在 deckList 之上、logPanel 之下。
        homePanel.onSelect = { [weak self] r in
            self?.onOpenProject(host: r.host, session: r.session, name: r.name, type: r.type.rawValue)
        }
        homePanel.onSelectRecording = { [weak self] r in self?.onTapRecording(r) }
        homePanel.isHidden = true
        view.addSubview(homePanel)
        logPanel.onClose = { [weak self] in self?.hideLogPanel(animated: true) }
        logPanel.isHidden = true
        view.addSubview(logPanel)

        // 原生终端(SwiftTerm),覆盖在列表之上,默认隐藏,终端态显示。
        TerminalKeyInterceptor.installOnce()   // swizzle pressesBegan 拦 F1/F2 + 语音 Enter/Esc
        let t = TerminalHostView(frame: view.bounds, font: TerminalFonts.terminalFont(size: 13))
        t.autoresizingMask = []   // 高度由 layoutTerm 按触屏 vkey 避让管理
        t.terminalDelegate = self
        t.keyHandler = self
        configureTerminalTheme(t)
        t.inputView = UIView(frame: .zero)   // 0 高度 → 不弹软键盘,但仍是键盘 first responder(硬件键进)
        t.isHidden = true
        view.addSubview(t)
        self.term = t

        // 禁掉 SwiftTerm 的文本选择/编辑菜单手势(长按/双击选词/三击/拖选),与触摸翻页冲突;保留滚动 + 单击翻页。
        for gr in t.gestureRecognizers ?? [] {
            if gr is UILongPressGestureRecognizer { gr.isEnabled = false }
            else if let tap = gr as? UITapGestureRecognizer, tap.numberOfTapsRequired >= 2 { gr.isEnabled = false }
            else if gr is UIPanGestureRecognizer, gr !== t.panGestureRecognizer { gr.isEnabled = false }
        }
        // terminal 触摸分区:底部语音热区(翻页改由右缘拨轮 scrollRail 接管,不再点屏翻页)。
        let voicePress = UILongPressGestureRecognizer(target: self, action: #selector(handleTermVoicePress(_:)))
        voicePress.minimumPressDuration = 0
        voicePress.cancelsTouchesInView = true
        voicePress.delegate = self
        t.addGestureRecognizer(voicePress)
        self.termVoicePress = voicePress
        let returnPan = UIPanGestureRecognizer(target: self, action: #selector(handleTermReturnPan(_:)))
        returnPan.delegate = self
        returnPan.cancelsTouchesInView = false
        t.addGestureRecognizer(returnPan)
        self.termReturnPan = returnPan

        // 触屏虚拟键盘:无硬件键盘时挂为终端 inputAccessoryView。
        let kb = TerminalKeyBar(width: view.bounds.width)
        kb.onAction = { [weak self] a in self?.handleKeyBarAction(a) }
        self.keyBar = kb
        updateTermAccessory()

        // 语音浮层最上层,默认隐藏。frame 由 layoutTerm 跟随 term(缩到 keybar 之上)。
        voiceOverlay.frame = view.bounds
        voiceOverlay.autoresizingMask = []
        voiceOverlay.onTapZone = { [weak self] zone in
            guard let self, self.view_ == .terminal else { return }
            switch zone {
            case .card:
                if self.voice.onEnter() {
                    self.keyHaptic.prepare(); self.keyHaptic.impactOccurred()
                }
            case .aboveCard:
                if self.voice.onEsc() {
                    self.keyHaptic.prepare(); self.keyHaptic.impactOccurred()
                } else {
                    self.tmuxModeLikely = false
                    self.sendToActivePTY(Data([27]))
                    self.keyHaptic.prepare(); self.keyHaptic.impactOccurred()
                }
            }
        }
        voiceOverlay.onVoicePress = { [weak self] down in self?.touchVoicePress(pressed: down) }
        voiceOverlay.onStopRecording = { [weak self] in self?.finishVoiceRecording() }
        voiceOverlay.onCancelRecording = { [weak self] in self?.cancelVoiceRecording() }
        view.addSubview(voiceOverlay)
        // 右缘无极拨轮(隐形触摸区,触摸显形;上下拖滚 + 惯性 + 逐行触觉)。
        scrollRail.delegate = self
        scrollRail.isHidden = true
        view.addSubview(scrollRail)
        // 底部"新消息"药丸:滚上去看历史时新输出不弹底,点它跳回最新。
        newMsgPill.isHidden = true
        newMsgPill.backgroundColor = UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
        newMsgPill.layer.cornerRadius = 16
        newMsgPill.layer.shadowColor = UIColor.black.cgColor
        newMsgPill.layer.shadowOpacity = 0.35
        newMsgPill.layer.shadowRadius = 8
        newMsgPill.layer.shadowOffset = CGSize(width: 0, height: 3)
        newMsgLabel.text = "▼ 新消息"
        newMsgLabel.textColor = .white
        newMsgLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        newMsgLabel.textAlignment = .center
        newMsgPill.addSubview(newMsgLabel)
        newMsgPill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(jumpToLatest)))
        view.addSubview(newMsgPill)

        terminalBottomCover.backgroundColor = Self.terminalBackgroundColor
        terminalBottomCover.isHidden = true
        view.addSubview(terminalBottomCover)
        channelStrip.isHidden = true
        channelStrip.textAlignment = .center
        channelStrip.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        channelStrip.textColor = .white
        channelStrip.numberOfLines = 1
        channelStrip.layer.borderWidth = 1 / UIScreen.main.scale
        channelStrip.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        channelStrip.isUserInteractionEnabled = false
        view.addSubview(channelStrip)

        setupVoice()
        RecordingLiveActivity.endStale()   // 清上次进程崩溃/被杀残留的录音 Live Activity
        fleetTriage.reloadConfig()   // 巡检判官(deepseek-v4-pro);无 correction.json → 降级

        // 录音后台投递:把 meta 里存的 {hostName,session} 解析成可投递 Target(用当前 hosts + via)。
        MeetingStore.shared.resolveTarget = { [weak self] t in
            guard let self, let h = self.hosts.first(where: { $0.name == t.hostName }) else { return nil }
            let via = h.via.flatMap { vn in self.hosts.first(where: { $0.name == vn }) }
            return MeetingDelegate.Target(host: h, via: via, session: t.session, projectName: t.projectName)
        }

        hosts = HostStore.loadHosts()
        NSLog("[VC] loaded \(hosts.count) hosts from hosts.json")
        AgentLog.info("app", "loaded hosts count=\(hosts.count)")
        deckList.setEmptyText(hosts.isEmpty ? "暂无 host\n\nAirDrop 一个 .xrhosts 配置导入" : nil)
        if !hosts.isEmpty {
            deckList.setSections(buildSections())   // 初始 = 全部 loading
            refreshManifests()
        }

        registerKeyboardObservers()
        registerForegroundObserver()
        registerKeyboardAvoidance()

        // iOS.6 边缘滑动:左缘右滑(终端)→ 回列表;右缘左滑(列表)→ 回到最近终端(iOS.7 保活)。
        for edge in [UIRectEdge.left, .right] {
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            g.edges = edge
            view.addGestureRecognizer(g)
        }
        let resumePan = UIPanGestureRecognizer(target: self, action: #selector(handleListResumePan(_:)))
        resumePan.delegate = self
        // cancelsTouchesInView=true:横滑手势一旦识别,取消底下 table cell 的触摸 → 不会误开 project;
        // 纯点击(无横向速度)不触发本手势 → cell 正常选中。解决"想滑回 Home 却点开了 Terminal"。
        resumePan.cancelsTouchesInView = true
        view.addGestureRecognizer(resumePan)
        self.listResumePan = resumePan
        let logPan = UIPanGestureRecognizer(target: self, action: #selector(handleListLogPan(_:)))
        logPan.delegate = self
        logPan.cancelsTouchesInView = true   // 同上:home 卡片上横滑去 logs 不误点开卡片
        view.addGestureRecognizer(logPan)
        self.listLogPan = logPan
        // 四页链:home 居 logs 与 list 之间。homePan 管 list↔home;logPan 改管 home↔logs。
        let homePan = UIPanGestureRecognizer(target: self, action: #selector(handleHomeListPan(_:)))
        homePan.delegate = self
        homePan.cancelsTouchesInView = true   // 列表 cell 上右滑回 Home 不误点开 project(用户反馈)
        view.addGestureRecognizer(homePan)
        self.homePan = homePan
        // 落地页 = 群控 Home(四页布局)。
        landOnHome()
        startTriageLoop()   // §14 巡检:前台周期跑;首轮语义刷新在 +25s,之前 Home 用 refreshManifests 的 hooks 降级

        #if DEBUG
        applyDebugLevers()
        #endif

        // 监听网络路径变化（WiFi↔蜂窝切换、断网→恢复），主动重建 SSH 连接。
        // monitor 本身由 AppDelegate 启动(app 级生命周期);这里只注册监听。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onNetworkPathChanged(_:)),
            name: NetworkMonitor.pathChangedNotification,
            object: nil
        )
    }

    @objc private func onNetworkPathChanged(_ note: Notification) {
        guard view_ == .terminal else { return }
        let available = (note.userInfo?["available"] as? Bool) ?? false
        // autoReconnectWork == nil:已有重连在飞时别重复触发,否则弱网抖动反复清零计数 → 击穿上限(issue #10)。
        if available && ssh == nil && warmHost != nil && autoReconnectWork == nil {
            // 网络恢复但 SSH 已断、且当前没有重连排程中 → 给一轮满额重连预算。
            AgentLog.info("network", "path recovered, try reconnect host=\(warmHost ?? "") session=\(warmSession ?? "")")
            autoReconnectAttempts = 0
            _ = scheduleAutoReconnect(
                host: warmHost!, session: warmSession ?? "",
                name: warmHost!, type: "claude", route: "net-recover"
            )
        }
    }

    private func configureTerminalTheme(_ terminalView: TerminalHostView) {
        terminalView.nativeBackgroundColor = Self.terminalBackgroundColor
        terminalView.nativeForegroundColor = Self.terminalForegroundColor
        let terminal = terminalView.getTerminal()
        terminal.ansi256PaletteStrategy = .xterm
        terminalView.installColors([
            Self.termColor(0x74, 0x78, 0x80), // ANSI black as foreground: visible on dark gray.
            Self.termColor(0xd4, 0x6a, 0x6a),
            Self.termColor(0x72, 0xbf, 0x78),
            Self.termColor(0xc6, 0xa8, 0x5a),
            Self.termColor(0x8e, 0xa3, 0xe6),
            Self.termColor(0xc4, 0x8d, 0xd7),
            Self.termColor(0x6f, 0xbb, 0xc2),
            Self.termColor(0xd6, 0xd8, 0xdc),
            Self.termColor(0x98, 0x9e, 0xa8),
            Self.termColor(0xe0, 0x7a, 0x7a),
            Self.termColor(0x89, 0xcc, 0x8d),
            Self.termColor(0xd9, 0xbc, 0x6c),
            Self.termColor(0xa8, 0xb6, 0xf0),
            Self.termColor(0xd2, 0xa0, 0xe2),
            Self.termColor(0x8a, 0xcf, 0xd5),
            Self.termColor(0xec, 0xee, 0xf2),
        ])
    }

    private static func termColor(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> Color {
        Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    /// iOS.6:终端左缘右滑 → 回列表;列表右缘左滑 → 滑回最近终端。跟手拖动,松手过阈值才提交。
    @objc private func handleEdgePan(_ g: UIScreenEdgePanGestureRecognizer) {
        let tx = g.translation(in: view).x
        let vx = g.velocity(in: view).x
        let width = max(view.bounds.width, 1)
        let threshold = min(140, width * 0.28)

        if g.edges == .left, view_ == .terminal {
            switch g.state {
            case .began:
                edgeDragging = true
            case .changed:
                slideTerminal(toX: min(width, max(0, tx)))
            case .ended:
                let shouldCommit = tx > threshold || vx > 650
                shouldCommit ? backToList(animated: true) : cancelTerminalSlide(toX: 0)
            case .cancelled, .failed:
                cancelTerminalSlide(toX: 0)
            default:
                break
            }
        } else if g.edges == .right, view_ == .list {
            switch g.state {
            case .began:
                prepareWarmPreviewFromRight()
            case .changed:
                guard edgeDragging else { return }
                slideTerminal(toX: min(width, max(0, width + tx)))
            case .ended:
                guard edgeDragging else { return }
                let shouldCommit = -tx > threshold || vx < -650
                shouldCommit ? resumeWarm(animated: true) : cancelTerminalSlide(toX: width, hideAfter: true)
            case .cancelled, .failed:
                if edgeDragging { cancelTerminalSlide(toX: width, hideAfter: true) }
            default:
                break
            }
        }
    }

    /// 列表页较宽区域左滑 → 回到最近 terminal。右缘 edge-pan 仍保留,这里降低触发门槛。
    @objc private func handleListResumePan(_ g: UIPanGestureRecognizer) {
        guard view_ == .list else { return }
        let tx = g.translation(in: view).x
        let vx = g.velocity(in: view).x
        let width = max(view.bounds.width, 1)
        let threshold = min(140, width * 0.28)

        switch g.state {
        case .began:
            prepareWarmPreviewFromRight()
        case .changed:
            guard edgeDragging else { return }
            slideTerminal(toX: min(width, max(0, width + tx)))
        case .ended:
            guard edgeDragging else { return }
            let shouldCommit = -tx > threshold || vx < -650
            shouldCommit ? resumeWarm(animated: true) : cancelTerminalSlide(toX: width, hideAfter: true)
        case .cancelled, .failed:
            if edgeDragging { cancelTerminalSlide(toX: width, hideAfter: true) }
        default:
            break
        }
    }

    /// 四页链之 home↔logs:home 右滑 → 日志容器;日志容器左滑 → 回 home。
    @objc private func handleListLogPan(_ g: UIPanGestureRecognizer) {
        let tx = g.translation(in: view).x
        let vx = g.velocity(in: view).x
        let width = max(view.bounds.width, 1)
        let threshold = min(140, width * 0.28)

        switch (view_, g.state) {
        case (.home, .began):
            prepareLogPanelFromLeft()
        case (.home, .changed):
            guard logDragging else { return }
            slideLogPanel(toX: min(0, -width + max(0, tx)))
        case (.home, .ended):
            guard logDragging else { return }
            let shouldCommit = tx > threshold || vx > 650
            shouldCommit ? showLogPanel(animated: true, alreadyPrepared: true) : cancelLogSlide(toX: -width, hideAfter: true)
        case (.home, .cancelled), (.home, .failed):
            if logDragging { cancelLogSlide(toX: -width, hideAfter: true) }

        case (.logs, .began):
            logDragging = true
            logPanel.isHidden = false
            view.bringSubviewToFront(logPanel)
        case (.logs, .changed):
            guard logDragging else { return }
            slideLogPanel(toX: max(-width, min(0, tx)))
        case (.logs, .ended):
            guard logDragging else { return }
            let shouldClose = -tx > threshold || vx < -650
            shouldClose ? hideLogPanel(animated: true) : showLogPanel(animated: true, alreadyPrepared: true)
        case (.logs, .cancelled), (.logs, .failed):
            if logDragging { showLogPanel(animated: true, alreadyPrepared: true) }
        default:
            break
        }
    }

    /// 四页链之 list↔home:列表右滑 → Home;Home 左滑 → 回列表。
    @objc private func handleHomeListPan(_ g: UIPanGestureRecognizer) {
        let tx = g.translation(in: view).x
        let vx = g.velocity(in: view).x
        let width = max(view.bounds.width, 1)
        let threshold = min(140, width * 0.28)

        switch (view_, g.state) {
        case (.list, .began):
            prepareHomePanelFromLeft()
        case (.list, .changed):
            guard homeDragging else { return }
            slideHomePanel(toX: min(0, -width + max(0, tx)))
        case (.list, .ended):
            guard homeDragging else { return }
            let shouldCommit = tx > threshold || vx > 650
            shouldCommit ? showHomePanel(animated: true, alreadyPrepared: true) : cancelHomeSlide(toX: -width, hideAfter: true)
        case (.list, .cancelled), (.list, .failed):
            if homeDragging { cancelHomeSlide(toX: -width, hideAfter: true) }

        case (.home, .began):
            homeDragging = true
            homePanel.isHidden = false
            view.bringSubviewToFront(homePanel)
        case (.home, .changed):
            guard homeDragging else { return }
            slideHomePanel(toX: max(-width, min(0, tx)))
        case (.home, .ended):
            guard homeDragging else { return }
            let shouldClose = -tx > threshold || vx < -650
            shouldClose ? hideHomePanel(animated: true) : showHomePanel(animated: true, alreadyPrepared: true)
        case (.home, .cancelled), (.home, .failed):
            if homeDragging { showHomePanel(animated: true, alreadyPrepared: true) }
        default:
            break
        }
    }

    /// terminal 页内容区右滑 → 回列表。只接明显横向右滑,避免抢垂直滚动/点按翻页。
    @objc private func handleTermReturnPan(_ g: UIPanGestureRecognizer) {
        guard view_ == .terminal else { return }
        let tx = g.translation(in: view).x
        let vx = g.velocity(in: view).x
        let width = max(view.bounds.width, 1)
        let threshold = min(140, width * 0.28)

        switch g.state {
        case .began:
            edgeDragging = true
        case .changed:
            slideTerminal(toX: min(width, max(0, tx)))
        case .ended:
            let shouldCommit = tx > threshold || vx > 650
            shouldCommit ? backToList(animated: true) : cancelTerminalSlide(toX: 0)
        case .cancelled, .failed:
            cancelTerminalSlide(toX: 0)
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let termVoicePress, gestureRecognizer === termVoicePress {
            guard view_ == .terminal, !term.isHidden else { return false }
            return terminalTouchZone(at: gestureRecognizer.location(in: term), height: term.bounds.height) == .voice
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        if let termReturnPan, gestureRecognizer === termReturnPan {
            guard view_ == .terminal, !term.isHidden else { return false }
            let v = pan.velocity(in: view)
            return v.x > 80 && abs(v.x) > abs(v.y) * 1.2
        }
        if let listResumePan, gestureRecognizer === listResumePan {
            guard view_ == .list, warmHost != nil else { return false }
            let startX = pan.location(in: view).x
            let v = pan.velocity(in: view)
            return startX > view.bounds.width * Self.listResumeStartFraction
                && v.x < -60
                && abs(v.x) > abs(v.y) * 1.05
        }
        if let listLogPan, gestureRecognizer === listLogPan {
            // home↔logs:home 右滑开 logs;logs 左滑回 home。
            let v = pan.velocity(in: view)
            if view_ == .home {
                return v.x > 60 && abs(v.x) > abs(v.y) * 1.05
            }
            if view_ == .logs {
                return v.x < -60 && abs(v.x) > abs(v.y) * 1.05
            }
            return false
        }
        if let homePan, gestureRecognizer === homePan {
            // list↔home:list 右滑开 home;home 左滑回 list。
            let v = pan.velocity(in: view)
            if view_ == .list {
                return v.x > 60 && abs(v.x) > abs(v.y) * 1.05
            }
            if view_ == .home {
                return v.x < -60 && abs(v.x) > abs(v.y) * 1.05
            }
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if let termReturnPan, gestureRecognizer === termReturnPan || otherGestureRecognizer === termReturnPan { return true }
        if let listResumePan, gestureRecognizer === listResumePan || otherGestureRecognizer === listResumePan { return true }
        if let listLogPan, gestureRecognizer === listLogPan || otherGestureRecognizer === listLogPan { return true }
        if let homePan, gestureRecognizer === homePan || otherGestureRecognizer === homePan { return true }
        return false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if view_ == .list || view_ == .home { becomeFirstResponder() }   // 列表/Home 态 VC 收硬件键
        // 根 VC 无可 pop,关掉 nav 的左缘返回手势 → 左缘留给我们的"终端回列表"(iOS.6)。
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTerm()
        layoutLogPanel()
        layoutHomePanel()
    }

    // MARK: - 列表数据:hosts + 状态 → [DeckSection](SPEC §3 状态映射,对齐 DeckJSON 逻辑)
    private func buildSections() -> [DeckSection] {
        hosts.map { h in
            let hostStatus = statusByHost[h.name] ?? [:]
            let hostLoading = (reachable == nil) || !probedHosts.contains(h.name)
            let unreachable = reachable != nil && !h.basePath.isEmpty && !(reachable!.contains(h.name))
            let rows = h.projects.map { p -> DeckRow in
                let live = hostStatus[p.session]
                let state: String? = {
                    if reachable == nil { return nil }   // 未探测
                    if hostLoading { return nil }        // 本 host 仍 loading
                    if unreachable { return "disconnected" }
                    return live?.state ?? "unknown"
                }()
                return DeckRow(host: h.name, session: p.session, name: p.name, type: p.type,
                               state: state, since: live?.since ?? 0, loading: hostLoading)
            }
            return DeckSection(hostName: h.name, addr: h.addr, proxy: hostProxyLabel(h), up: hostLoading || !unreachable, rows: rows)
        }
    }

    private func hostProxyLabel(_ h: HostConfig) -> String {
        if h.via == nil { return h.proxy?.name ?? "" }
        let jumper = hosts.first { $0.name == h.via }
        return jumper?.proxy?.name ?? h.proxy?.name ?? ""
    }

    private func pushList() {
        if view_ == .list { deckList.setSections(buildSections()) }
    }

    /// Fetch each host's manifest + status off the main actor (concurrent + per-host timeout in
    /// ManifestFetcher), pushing the list INCREMENTALLY as each host resolves (SPEC §9). `fetchGen`
    /// discards a superseded fetch.
    private func refreshManifests() {
        let snapshot = hosts
        AgentLog.info("manifest", "refresh start hosts=\(snapshot.count)")
        fetchGen += 1
        let gen = fetchGen
        Task {
            let result = await ManifestFetcher.fetch(snapshot) { [weak self] r in
                guard let self, gen == self.fetchGen else { return }
                let level: AgentLogLevel = !r.liveFetched ? .debug : (r.reachable ? .info : .warn)
                AgentLog.shared.log(level, "manifest", "\(r.host.name) resolved reachable=\(r.reachable) projects=\(r.host.projects.count) states=\(r.status.count)")
                self.probedHosts.insert(r.host.name)
                self.statusByHost[r.host.name] = r.status
                if r.liveFetched {
                    var reach = self.reachable ?? []
                    if r.reachable { reach.insert(r.host.name) } else { reach.remove(r.host.name) }
                    self.reachable = reach
                }
                self.hosts = self.hosts.map { $0.name == r.host.name ? r.host : $0 }
                self.pushList()
                self.pushHome()
            }
            await MainActor.run {
                guard gen == self.fetchGen else { return }
                self.hosts = result.hosts
                self.statusByHost = result.statusByHost
                self.reachable = result.reachable
                self.probedHosts = Set(result.hosts.map { $0.name })
                self.pushList()
                self.pushHome()
                AgentLog.info("manifest", "refresh done reachable=\(result.reachable.count)/\(result.hosts.count)")
                #if DEBUG
                self.maybeAutoOpen()
                #endif
            }
        }
    }

    // MARK: - Open project → PTY
    private func onOpenProject(host: String, session: String, name: String, type: String, resetAutoReconnect: Bool = true) {
        NSLog("[VC] openProject host=\(host) session=\(session)")
        AgentLog.info("terminal", "open host=\(host) session=\(session) type=\(type)")
        if resetAutoReconnect {
            autoReconnectAttempts = 0
            cancelAutoReconnect()
        }
        // iOS.7:命中保活终端 → 瞬间滑回原终端(不重连);否则关掉上一个保活终端再连新的。
        if host == warmHost, session == warmSession, ssh != nil { resumeWarm(); return }
        closeWarm()
        let seq = { openSeq += 1; return openSeq }()
        view_ = .terminal
        showTerminalView(clear: true)   // 新连接:清屏
        setChannelStrip(.hidden)

        guard let h = hosts.first(where: { $0.name == host }),
              let p = (h.projects.first(where: { $0.session == session })) else {
            applyVoiceContext(nil)
            AgentLog.warn("terminal", "missing SSH config for session=\(session)")
            writeToTerm("\r\n[no SSH config for \(session)]\r\n")
            return
        }
        warmHost = host; warmSession = session   // 记下当前终端身份(保活用)
        applyVoiceContext(p)
        let jump = h.via.flatMap { vn in hosts.first(where: { $0.name == vn }) }
        activeHostConfig = h
        activeViaConfig = jump
        activeSessionName = p.session
        tmuxModeLikely = false
        let usesProxy = jump?.proxy != nil || (jump == nil && h.proxy != nil)
        let reconnectRoute = usesProxy ? "proxy" : (jump != nil ? "via" : "direct")   // 日志/提示用标签;直连也会重连
        let viaNote = jump.map { " ⤳ \($0.name)" } ?? ""
        writeToTerm("连接 \(h.name)\(viaNote) … (\(p.session))\r\n")   // alias, never the real IP

        let gen = { sessionGen += 1; return sessionGen }()
        let s = SSHSession()
        s.onOutput = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.sessionGen == gen else { return }   // late chunk from closed session
                self.outputSeq += 1
                if self.channelStripState == .checking || self.channelStripState == .suspect || self.channelStripState == .reconnecting {
                    self.setChannelStrip(.hidden)
                }
                // 滚动锁:用户滚上去看历史(非底部)时,记下"有新内容"→ 底部药丸提示,不打断阅读。
                let wasAtBottom = !self.term.canScroll || self.term.scrollPosition >= 0.999
                self.term.feed(byteArray: ArraySlice(data))
                if self.view_ == .terminal, !wasAtBottom, !self.tmuxModeLikely, self.term.canScroll {
                    self.newMsgCount += 1
                    self.showNewMsgPill()
                }
            }
        }
        s.onClosed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.sessionGen == gen, self.ssh === s else { return }
                NSLog("[VC] PTY dropped gen=\(gen) view=\(self.view_ == .terminal ? "term" : "warm")")
                AgentLog.warn("terminal", "PTY dropped host=\(h.name) session=\(p.session)")
                self.ssh = nil
                self.warmHost = nil; self.warmSession = nil   // 保活终端也断了 → 清理
                self.activeHostConfig = nil
                self.activeViaConfig = nil
                self.activeSessionName = nil
                self.tmuxModeLikely = false
                self.cancelKeepWarm()
                if self.view_ == .terminal {
                    if self.scheduleAutoReconnect(host: h.name, session: p.session, name: p.name, type: p.type.rawValue, route: reconnectRoute) { return }
                    self.setChannelStrip(.disconnected, "SSH 通道已断开，返回列表重开此 project")
                    self.writeToTerm("\r\n\u{1b}[33m[连接已断开 — 按返回键回到列表,重开此 project 可重连]\u{1b}[0m\r\n")
                }
            }
        }
        s.connect(host: h, via: jump, session: p.session, cols: 80, rows: 24,
            onConnected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if seq != self.openSeq {   // 被更新的 open 取代 → 丢弃
                        NSLog("[VC] PTY connected but superseded (seq=\(seq)) → close")
                        s.close(); return
                    }
                    self.ssh = s   // 绑上;若用户连接途中已 back(view_ == .list)= 保活,session 照样绑上
                    // 纠错的 tmux 背景来源:在**已有**连接上抓 capture-pane(复用连接;弱引用 s 防泄漏)。
                    let captureSession = p.session
                    self.voice.terminalContext = { [weak s] in
                        await s?.execCapture(SSHSession.tmuxCaptureCommand(captureSession))
                    }
                    self.voice.prewarmCorrector()   // 进 project 即预热 LLM 连接,首次纠错不付握手
                    self.outputSeq = 0
                    self.cancelEchoWatch()
                    self.setChannelStrip(.hidden)
                    self.autoReconnectAttempts = 0
                    self.cancelAutoReconnect()
                    NSLog("[VC] PTY live host=\(h.name) session=\(p.session) view=\(self.view_ == .terminal ? "term" : "warm")")
                    AgentLog.info("terminal", "PTY live host=\(h.name) session=\(p.session)")
                    if self.view_ == .terminal {
                        let t = self.term.getTerminal()
                        self.ssh?.resize(cols: t.cols, rows: t.rows)   // 补推当前终端尺寸
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-autoTypeAfterOpen") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.sendToActivePTY(Data("echo XREAL_OK\n".utf8)) }
                    }
                    #endif
                }
            },
            onFailure: { [weak self] err in
                DispatchQueue.main.async {
                    guard let self, seq == self.openSeq else { return }
                    NSLog("[VC] PTY connect failed: \(err)")
                    AgentLog.error("terminal", "connect failed host=\(h.name) session=\(p.session): \(err.prefix(180))")
                    if self.warmHost == h.name, self.warmSession == p.session {
                        self.warmHost = nil; self.warmSession = nil
                        self.cancelKeepWarm()
                    }
                    if self.view_ == .terminal {
                        if self.scheduleAutoReconnect(host: h.name, session: p.session, name: p.name, type: p.type.rawValue, route: reconnectRoute) { return }
                        self.setChannelStrip(.disconnected, "SSH 连接失败")
                        self.writeToTerm("\r\nSSH 连接失败: \(err)\r\n")
                    }
                }
            }
        )
    }

    private func backToList(animated: Bool = false) {
        NSLog("[VC] backToList (keep-warm)")
        AgentLog.debug("ui", "back to list keepWarm=\(ssh != nil || warmHost != nil)")
        voiceKeyHeld = false
        voice.shutdown()
        applyVoiceContext(nil)
        // iOS.7 保活:**不关 ssh**,SwiftTerm 绘制保留、后台继续喂输出;keepWarmSeconds 后超时真关。
        // 列表右缘滑 / 重开同一 project = 瞬间滑回(不重连)。
        if ssh != nil || warmHost != nil { scheduleKeepWarm() }
        // §14:记下用户离开这个 agent 时最后看到的画面,作为巡检判官 baseline(只报"自上次所见以来的新决策")。
        if let h = warmHost, let sess = warmSession, let conn = ssh {
            Task { [weak self, weak conn] in
                let tail = await conn?.execCapture(SSHSession.tmuxCaptureCommand(sess)) ?? ""
                await MainActor.run { self?.fleetTriage.markSeen(host: h, session: sess, tail: tail) }
            }
        }
        if animated {
            showListViewSlidingOut { [weak self] in
                guard let self else { return }
                self.view_ = .list
                self.showListView(reloadList: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, self.view_ == .list else { return }
                    self.refreshManifests()   // a project Maestro just created shows up now
                }
            }
        } else {
            view_ = .list
            showListView()
            refreshManifests()
        }
    }

    // MARK: - iOS.7 最近终端保活
    private func scheduleKeepWarm() {
        keepWarmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSLog("[VC] keep-warm 超时 → 关闭最近终端 SSH(tmux session 服务端仍在)")
            AgentLog.debug("terminal", "keep-warm timeout, close SSH client")
            self?.closeWarm()
        }
        keepWarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepWarmSeconds, execute: work)
    }
    private func cancelKeepWarm() { keepWarmWork?.cancel(); keepWarmWork = nil }
    private func cancelAutoReconnect() { autoReconnectWork?.cancel(); autoReconnectWork = nil }
    private func cancelEchoWatch() { echoWatchWork?.cancel(); echoWatchWork = nil }
    @discardableResult
    private func scheduleAutoReconnect(host: String, session: String, name: String, type: String, route: String) -> Bool {
        guard autoReconnectAttempts < Self.maxReconnectAttempts else { return false }
        cancelAutoReconnect()   // 防御:同时只允许一个重连 work 在飞,避免多触发源(网络回调 + PTY drop)叠加排程
        autoReconnectAttempts += 1
        let attempt = autoReconnectAttempts
        // 指数退避:1s→2s→4s→8s→16s,弱网下给链路恢复留时间,不疯狂重试耗尽电池。
        let delay = pow(2.0, Double(attempt - 1))
        AgentLog.warn("network", "\(route) PTY dropped, auto reconnect \(attempt)/\(Self.maxReconnectAttempts) delay=\(Int(delay))s host=\(host) session=\(session)")
        setChannelStrip(.reconnecting, "SSH 通道中断，正在重连 \(attempt)/\(Self.maxReconnectAttempts)…")
        writeToTerm("\r\n\u{1b}[33m[SSH 通道断开,正在自动重连 \(attempt)/\(Self.maxReconnectAttempts)…]\u{1b}[0m\r\n")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.view_ == .terminal else { return }
            self.autoReconnectWork = nil
            self.onOpenProject(host: host, session: session, name: name, type: type, resetAutoReconnect: false)
        }
        autoReconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

    private func sendToActivePTY(_ data: Data, expectOutput: Bool = true) {
        guard let ssh else {
            setChannelStrip(.disconnected, "SSH 通道已断开，返回列表重开此 project")
            return
        }
        ssh.send(data)
        if expectOutput { scheduleEchoWatch() }
    }

    private func scheduleEchoWatch() {
        cancelEchoWatch()
        let gen = sessionGen
        let out = outputSeq
        let h = activeHostConfig
        let via = activeViaConfig
        let session = activeSessionName
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.view_ == .terminal,
                  self.sessionGen == gen,
                  self.outputSeq == out,
                  self.ssh != nil else { return }
            self.setChannelStrip(.checking, "SSH 通道无回显，正在检查…")
            AgentLog.warn("terminal", "PTY no output after user input, probing channel")
            guard let h, let session else {
                self.setChannelStrip(.suspect, "SSH 通道无回显，可能已卡住")
                return
            }
            Task {
                let ok = await TmuxModeProbe.paneInMode(host: h, via: via, session: session) != nil
                await MainActor.run {
                    guard self.view_ == .terminal,
                          self.sessionGen == gen,
                          self.outputSeq == out,
                          self.ssh != nil else { return }
                    if ok {
                        self.setChannelStrip(.suspect, "交互 SSH 无回显，可能已卡住；可返回列表重开")
                    } else {
                        self.setChannelStrip(.disconnected, "SSH 探测失败，通道可能已断开")
                    }
                }
            }
        }
        echoWatchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noEchoGraceSeconds, execute: work)
    }

    private func setChannelStrip(_ state: ChannelStripState, _ message: String = "") {
        channelStripState = state
        guard view_ == .terminal, state != .hidden else {
            channelStrip.isHidden = true
            return
        }
        channelStrip.text = message
        switch state {
        case .hidden:
            channelStrip.isHidden = true
            return
        case .checking:
            channelStrip.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.82)
        case .suspect:
            channelStrip.backgroundColor = UIColor(red: 0.86, green: 0.48, blue: 0.10, alpha: 0.90)
        case .reconnecting:
            channelStrip.backgroundColor = UIColor(red: 0.64, green: 0.36, blue: 0.92, alpha: 0.90)
        case .disconnected:
            channelStrip.backgroundColor = UIColor.systemRed.withAlphaComponent(0.92)
        }
        channelStrip.isHidden = false
        layoutChannelStrip()
        view.bringSubviewToFront(channelStrip)
        view.bringSubviewToFront(voiceOverlay)
    }

    /// 真正关掉保活终端的 SSH(client 断;tmux session 服务端持久)。bump 计数失活在途连接/迟到输出。
    private func closeWarm() {
        cancelAutoReconnect()
        cancelKeepWarm()
        cancelEchoWatch()
        openSeq += 1; sessionGen += 1
        let old = ssh; ssh = nil
        old?.close()
        warmHost = nil; warmSession = nil
        activeProjectType = nil
        activeHostConfig = nil
        activeViaConfig = nil
        activeSessionName = nil
        tmuxModeLikely = false
        setChannelStrip(.hidden)
    }
    /// 回到最近终端:已连接时瞬间恢复;连接中时回到原连接页,等 onConnected 继续绑定。
    private func resumeWarm(animated: Bool = false) {
        guard warmHost != nil else { return }   // 无保活终端(或已超时/失败清理)→ 不动
        NSLog("[VC] resume warm terminal \(warmHost ?? "")/\(warmSession ?? "")")
        AgentLog.debug("terminal", "resume warm host=\(warmHost ?? "") session=\(warmSession ?? "")")
        cancelKeepWarm()
        if let h = hosts.first(where: { $0.name == warmHost }),
           let p = h.projects.first(where: { $0.session == warmSession }) {
            applyVoiceContext(p)
            activeHostConfig = h
            activeViaConfig = h.via.flatMap { vn in hosts.first(where: { $0.name == vn }) }
            activeSessionName = p.session
        }
        view_ = .terminal
        animated ? showTerminalViewSlidingIn() : showTerminalView(clear: false)   // **不清屏**:保留原内容
        let t = term.getTerminal()
        ssh?.resize(cols: t.cols, rows: t.rows)
    }

    // MARK: - 终端/列表 view 切换
    private func showTerminalView(clear: Bool = true) {
        logPanel.isHidden = true
        logDragging = false
        homePanel.isHidden = true
        homeDragging = false
        if clear { term.feed(text: "\u{1b}c") }   // 新连接 RIS 全复位;保活滑回**不清屏**(保留原内容)
        suppressTermAccessory = false
        primeTermAccessoryForTerminal()
        slideTerminal(toX: 0)
        view.bringSubviewToFront(term)
        view.bringSubviewToFront(channelStrip)
        view.bringSubviewToFront(scrollRail)
        view.bringSubviewToFront(newMsgPill)
        view.bringSubviewToFront(voiceOverlay)
        view.bringSubviewToFront(terminalBottomCover)
        term.isHidden = false
        scrollRail.isHidden = false
        _ = term.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view_ == .terminal, !self.edgeDragging else { return }
            self.primeTermAccessoryForTerminal()
            self.layoutTerm()
        }
        navigationController?.setNavigationBarHidden(true, animated: false)  // 终端沉浸:隐藏 nav bar
        setNeedsStatusBarAppearanceUpdate()                                  // + 状态栏 + home indicator
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    private func showListView(reloadList: Bool = true) {
        voiceOverlay.hide()
        logPanel.isHidden = true
        logDragging = false
        homePanel.isHidden = true
        homeDragging = false
        layoutHomePanel()
        suppressTermAccessory = true
        updateTermAccessory()
        _ = term.resignFirstResponder()
        clearForcedKeyboardOverlap()
        term.isHidden = true
        scrollRail.isHidden = true
        hideNewMsgPill()
        setChannelStrip(.hidden)
        terminalBottomCover.isHidden = true
        _ = becomeFirstResponder()      // 列表态 VC 收硬件键 → 列表导航
        if reloadList { pushList() }
        navigationController?.setNavigationBarHidden(false, animated: false) // 列表:恢复 nav bar(大标题)
        navigationItem.title = "Agent Station"
        navigationItem.largeTitleDisplayMode = .always
        if navigationItem.rightBarButtonItem == nil {   // 从 logs 回列表 → 恢复齿轮
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "slider.horizontal.3"),
                style: .plain, target: self, action: #selector(presentHostManager))
        }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    // MARK: - 日志容器
    private func layoutLogPanel() {
        guard !logDragging else { return }
        let x: CGFloat = view_ == .logs ? 0 : -view.bounds.width
        logPanel.frame = view.bounds.offsetBy(dx: x, dy: 0)
    }

    private func prepareLogPanelFromLeft() {
        logDragging = true
        logPanel.refresh()
        logPanel.isHidden = false
        slideLogPanel(toX: -view.bounds.width)
        view.bringSubviewToFront(logPanel)
    }

    private func slideLogPanel(toX x: CGFloat) {
        logPanel.frame = view.bounds.offsetBy(dx: x, dy: 0)
    }

    private func showLogPanel(animated: Bool, alreadyPrepared: Bool = false) {
        if !alreadyPrepared { prepareLogPanelFromLeft() }
        view_ = .logs
        navigationItem.title = ""
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = nil   // 齿轮只在列表态
        navigationController?.setNavigationBarHidden(false, animated: false)
        logPanel.refresh()
        logPanel.isHidden = false
        view.bringSubviewToFront(logPanel)
        let finish = {
            self.logDragging = false
            self.slideLogPanel(toX: 0)
        }
        guard animated else { finish(); return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: finish)
    }

    /// logs 在 home 左侧 → 关 logs 退回 **home**(不是 list)。home 面板本就在 x=0 后面,只需把 logs 滑走。
    private func hideLogPanel(animated: Bool) {
        view_ = .home
        navigationItem.title = ""
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.setNavigationBarHidden(true, animated: false)
        homePanel.render(buildHomeModel())
        homePanel.isHidden = false
        layoutHomePanel()   // view_==.home → x=0,露在 logPanel 之下
        let finish = {
            self.logDragging = false
            self.slideLogPanel(toX: -self.view.bounds.width)
        }
        let completion: (Bool) -> Void = { _ in
            self.logPanel.isHidden = true
            self.layoutLogPanel()
        }
        guard animated else {
            finish()
            completion(true)
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: finish, completion: completion)
    }

    private func cancelLogSlide(toX x: CGFloat, hideAfter: Bool = false) {
        UIView.animate(withDuration: 0.20, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.slideLogPanel(toX: x)
        } completion: { _ in
            self.logDragging = false
            if hideAfter { self.logPanel.isHidden = true }
            self.layoutLogPanel()
        }
    }

    // MARK: - 群控 Home(四页布局落地页;SPEC §14 展示面。机制同 logPanel)
    /// home 在 logs 与 list 之间:home 盖 list,logs 盖 home。home 处于 x=0 当 view 为 .home 或 .logs。
    private func layoutHomePanel() {
        guard !homeDragging else { return }
        let x: CGFloat = (view_ == .home || view_ == .logs) ? 0 : -view.bounds.width
        homePanel.frame = view.bounds.offsetBy(dx: x, dy: 0)
    }
    private func slideHomePanel(toX x: CGFloat) {
        homePanel.frame = view.bounds.offsetBy(dx: x, dy: 0)
    }
    private func prepareHomePanelFromLeft() {
        homeDragging = true
        homePanel.render(buildHomeModel())
        homePanel.isHidden = false
        slideHomePanel(toX: -view.bounds.width)
        view.bringSubviewToFront(homePanel)
    }
    private func showHomePanel(animated: Bool, alreadyPrepared: Bool = false) {
        if !alreadyPrepared { prepareHomePanelFromLeft() }
        view_ = .home
        navigationItem.title = ""
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.setNavigationBarHidden(true, animated: false)   // Home 全屏深色仪表盘,隐藏 nav bar
        MeetingStore.shared.processPending()   // 滑入 Home:把待处理录音跑起来
        homePanel.render(buildHomeModel())
        homePanel.isHidden = false
        view.bringSubviewToFront(homePanel)
        _ = becomeFirstResponder()
        let finish = {
            self.homeDragging = false
            self.slideHomePanel(toX: 0)
        }
        guard animated else { finish(); return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: finish)
    }
    /// home 在 list 左侧 → 关 home 退回 **list**(home 滑走,露出后面的 list)。
    private func hideHomePanel(animated: Bool) {
        view_ = .list
        navigationController?.setNavigationBarHidden(false, animated: false)   // 回列表:恢复 nav bar
        navigationItem.title = "Agent Station"
        navigationItem.largeTitleDisplayMode = .always
        _ = becomeFirstResponder()
        pushList()
        let finish = {
            self.homeDragging = false
            self.slideHomePanel(toX: -self.view.bounds.width)
        }
        let completion: (Bool) -> Void = { _ in
            self.homePanel.isHidden = true
            self.layoutHomePanel()
        }
        guard animated else { finish(); completion(true); return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: finish, completion: completion)
    }
    private func cancelHomeSlide(toX x: CGFloat, hideAfter: Bool = false) {
        UIView.animate(withDuration: 0.20, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.slideHomePanel(toX: x)
        } completion: { _ in
            self.homeDragging = false
            if hideAfter { self.homePanel.isHidden = true }
            self.layoutHomePanel()
        }
    }

    /// 启动落地在 Home(四页布局)。list 已是默认可见 anchor,home 盖其上。
    private func landOnHome() {
        view_ = .home
        navigationItem.title = ""
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.setNavigationBarHidden(true, animated: false)   // Home 全屏深色仪表盘,隐藏 nav bar
        MeetingStore.shared.processPending()   // 启动落地 Home:把待处理录音跑起来
        homePanel.render(buildHomeModel())
        homePanel.isHidden = false
        layoutHomePanel()
        view.bringSubviewToFront(homePanel)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    /// Home 模型。有巡检 digest(§14)→ 用它(带 why/urgency,已过滤 needsYou);否则 hooks 降级
    /// (§14.4:列 waiting/needs-permission,无"为什么")。working/hostCount 始终从 hooks 状态算。
    private func buildHomeModel() -> HomePanelView.Model {
        let probing = (reachable == nil)
        var working = 0
        var offline = 0
        for h in hosts {
            let st = statusByHost[h.name] ?? [:]
            let hostLoading = (reachable == nil) || !probedHosts.contains(h.name)
            let unreachable = reachable != nil && !h.basePath.isEmpty && !(reachable!.contains(h.name))
            if hostLoading { continue }
            if unreachable { offline += h.projects.count; continue }   // 整 host 不可达 → 其 project 全离线
            for p in h.projects {
                switch st[p.session]?.state {
                case "working":      working += 1
                case "disconnected": offline += 1
                default:             break
                }
            }
        }
        let attention: [HomePanelView.HomeRow]
        if let items = triageItems {
            attention = items.map {
                .init(host: $0.host, session: $0.session, name: $0.name, type: $0.type,
                      state: $0.state, since: $0.since, why: $0.why, urgency: $0.urgency)
            }
        } else {
            attention = hooksAttention()
        }
        let all = recordingRows()
        return .init(attention: attention,
                     recordingsPending: all.filter { $0.state != "done" },
                     recordingsProcessed: all.filter { $0.state == "done" },
                     working: working, offline: offline,
                     hostCount: hosts.count, probing: probing, judgeActive: fleetTriage.hasJudge)
    }

    /// 巡检尚未出结果时的占位:**只列 needs-permission**(明确的权限抉择)。单纯 waiting 是常态
    /// (干完一轮停着等下一步),不进「需要你」——和 §14 判官 / 降级口径一致。巡检一跑完即被 digest 取代。
    private func hooksAttention() -> [HomePanelView.HomeRow] {
        var rows: [HomePanelView.HomeRow] = []
        for h in hosts {
            let st = statusByHost[h.name] ?? [:]
            let hostLoading = (reachable == nil) || !probedHosts.contains(h.name)
            let unreachable = reachable != nil && !h.basePath.isEmpty && !(reachable!.contains(h.name))
            guard !hostLoading, !unreachable else { continue }
            for p in h.projects {
                guard let s = st[p.session], s.state == "needs-permission" else { continue }
                rows.append(.init(host: h.name, session: p.session, name: p.name, type: p.type,
                                  state: s.state, since: s.since, why: "等待权限确认", urgency: "high"))
            }
        }
        rows.sort { ($0.since == 0 ? Int.max : $0.since) < ($1.since == 0 ? Int.max : $1.since) }
        return rows
    }

    /// home 数据刷新(随 manifest/status 更新)。off-screen 也刷,保证滑入即新。
    private func pushHome() {
        homePanel.render(buildHomeModel())
    }

    /// MeetingStore 任务 → Home 录音行(独立于 host)。
    private func recordingRows() -> [HomePanelView.RecordingRow] {
        MeetingStore.shared.tasks().map {
            .init(id: $0.audioURL.lastPathComponent, name: $0.name,
                  state: $0.state.rawValue, detail: $0.detail,
                  since: Int($0.receivedAt.timeIntervalSince1970))
        }
    }

    /// 点录音卡片:已处理/待投递→预览(可委托/重投/删);待转译→开始转写;失败→重试/删除;进行中→忽略。
    private func onTapRecording(_ r: HomePanelView.RecordingRow) {
        guard let task = MeetingStore.shared.tasks().first(where: { $0.audioURL.lastPathComponent == r.id }) else { return }
        switch task.state {
        case .done:
            presentPreview(for: task)                      // 已投递:预览,可重投到别的 session / 删
        case .received:
            if task.transcribed { presentPreview(for: task) }   // 已转译,待投递 → 预览里选 subproject 委托
            else { MeetingStore.shared.process(task.audioURL) } // 待转译 → 开始转写(有目标会自动投递)
        case .failed:
            let a = UIAlertController(title: task.name, message: "这条「\(task.detail)」,可重试。", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "重试", style: .default) { _ in MeetingStore.shared.retry(task) })
            if task.transcribed {
                a.addAction(UIAlertAction(title: "查看逐字稿", style: .default) { [weak self] _ in self?.presentPreview(for: task) })
            }
            a.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                MeetingStore.shared.remove(task); self?.pushHome()
            })
            a.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(a, animated: true)
        case .processing:
            break
        }
    }

    /// 录音逐字稿预览:删除 / 委托。委托成功 → markDelivered(移入「已处理」)。
    private func presentPreview(for task: RecordingTask) {
        let text = MeetingStore.shared.transcript(for: task) ?? "(空)"
        let preview = MeetingPreviewVC(
            name: task.name, markdown: text, hosts: hosts,
            onDelete: { [weak self] in MeetingStore.shared.remove(task); self?.pushHome() },
            onDelivered: { [weak self] target in
                MeetingStore.shared.markDelivered(task, to: .init(
                    hostName: target.host.name, session: target.session, projectName: target.projectName))
                self?.pushHome()
            })
        let nav = UINavigationController(rootViewController: preview)
        nav.modalPresentationStyle = .fullScreen
        nav.overrideUserInterfaceStyle = .dark
        present(nav, animated: true)
    }

    // MARK: - 舰队巡检 loop(SPEC §14)
    /// 周期定时器(前台才 fire)。tick 自门:仅 Home/列表态 + 有 basePath host 才跑一轮。
    private func startTriageLoop() {
        triageTimer?.invalidate()
        let t = Timer(timeInterval: Self.triageIntervalSeconds, repeats: true) { [weak self] _ in
            self?.triageTick()
        }
        RunLoop.main.add(t, forMode: .common)
        triageTimer = t
    }
    private func triageTick() {
        // home/list/terminal 都跑:终端态也巡检 → 你埋头在某 agent 时,别的 agent 卡住能 banner 提醒。
        guard view_ == .home || view_ == .list || view_ == .terminal else { return }
        guard hosts.contains(where: { !$0.basePath.isEmpty }) else { return }
        runTriageRound()
    }
    /// 跑一轮巡检:digest 喂 Home,顺带用这一轮 fresh fetch 刷新列表状态(巡检 = Home/列表的 live 刷新)。
    /// `runOnce` 内部 `running` 防重入;不动 `fetchGen`(那是事件驱动 refresh 的序号,互不干涉,末写为准)。
    private func runTriageRound() {
        guard hosts.contains(where: { !$0.basePath.isEmpty }) else { return }
        Task {
            guard let round = await fleetTriage.runOnce(hosts: hosts) else { return }  // nil = 上一轮还在跑,跳过
            self.hosts = round.fetch.hosts
            self.statusByHost = round.fetch.statusByHost
            self.reachable = round.fetch.reachable
            self.probedHosts = Set(round.fetch.hosts.map { $0.name })
            self.triageItems = round.items
            self.pushList()
            self.pushHome()
            // app 内通知:本轮"新出现"的「需要你」→ 顶部 banner。Home 态不弹(列表已列着);首轮只建基线。
            let keys = Set(round.items.map { $0.host + "\u{1}" + $0.session })
            let newKeys = keys.subtracting(self.lastNeedsYouKeys)
            self.lastNeedsYouKeys = keys
            if self.triageBaselineSet, self.view_ != .home, !newKeys.isEmpty {
                self.showAttentionBanner(round.items.filter { newKeys.contains($0.host + "\u{1}" + $0.session) })
            }
            self.triageBaselineSet = true
        }
    }

    /// app 内通知(SPEC §14 送达面的最简版)。顶部胶囊 banner,提醒有新 agent 需要你处理。
    /// (系统级 push / 后台通知是更大的活,押后;这里只在 app 前台时弹。)
    private func showAttentionBanner(_ items: [TriageItem]) {
        guard !items.isEmpty else { return }
        let high = items.contains { $0.urgency == "high" }
        let text: String
        if items.count == 1 {
            let it = items[0]
            text = "🔔 \(it.name) 需要你" + (it.why.isEmpty ? "" : "\n\(it.why)")
        } else {
            text = "🔔 \(items.count) 个 agent 需要你处理"
        }
        let lbl = PaddingLabel()
        lbl.text = text
        lbl.font = .systemFont(ofSize: 14, weight: .semibold)
        lbl.textColor = .white
        lbl.backgroundColor = (high ? UIColor.systemRed : UIColor.systemOrange).withAlphaComponent(0.96)
        lbl.layer.cornerRadius = 12; lbl.clipsToBounds = true
        lbl.numberOfLines = 0; lbl.textAlignment = .center
        lbl.alpha = 0
        lbl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lbl)
        view.bringSubviewToFront(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lbl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            lbl.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])
        UINotificationFeedbackGenerator().notificationOccurred(high ? .warning : .success)
        UIView.animate(withDuration: 0.25, animations: { lbl.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.5, delay: 3.8, options: []) { lbl.alpha = 0 } completion: { _ in lbl.removeFromSuperview() }
        }
    }

    private var shouldShowTermAccessory: Bool { GCKeyboard.coalesced == nil }

    private func predictedKeyBarOverlap() -> CGFloat {
        guard shouldShowTermAccessory, let keyBar else { return 0 }
        let width = view.bounds.width > 0 ? view.bounds.width : max(keyBar.bounds.width, keyBar.frame.width)
        keyBar.frame.size.width = width
        keyBar.setNeedsLayout()
        keyBar.layoutIfNeeded()
        let bottomInset = max(keyBar.safeAreaInsets.bottom, view.safeAreaInsets.bottom)
        return TerminalKeyBar.preferredHeight(width: width, bottomInset: bottomInset)
    }

    private func primeTermAccessoryForTerminal() {
        updateTermAccessory()
        guard shouldShowTermAccessory else {
            clearForcedKeyboardOverlap()
            return
        }
        let cached = abs(cachedKeyBarWidth - view.bounds.width) < 2 ? cachedKeyBarOverlap : 0
        forcedKeyboardOverlap = max(keyboardOverlap, cached, predictedKeyBarOverlap())
    }

    private func freezeCurrentTermOverlapForSlide() {
        guard shouldShowTermAccessory else { return }
        forcedKeyboardOverlap = max(forcedKeyboardOverlap ?? 0, keyboardOverlap, predictedKeyBarOverlap())
    }

    private func clearForcedKeyboardOverlap() {
        forcedKeyboardOverlap = nil
    }

    private func termBaseFrame() -> CGRect {
        let overlap = forcedKeyboardOverlap ?? keyboardOverlap
        // terminal 核心区 = 整屏扣掉 vkey/inputAccessoryView overlap;5-unit 热区和 overlay 三段都基于这个 frame。
        return CGRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - overlap))
    }
    private func slideTerminal(toX x: CGFloat) {
        let base = termBaseFrame()
        let f = base.offsetBy(dx: x, dy: 0)
        term.frame = f
        voiceOverlay.frame = f
        voiceOverlay.reservedBottomInset = terminalBottomVoiceZoneHeight(in: f.height)
        layoutChannelStrip()
        layoutScrollRail()
        if !terminalBottomCover.isHidden {
            terminalBottomCover.frame = CGRect(
                x: x,
                y: base.maxY,
                width: base.width,
                height: max(0, view.bounds.height - base.maxY)
            )
        }
    }
    private func prepareWarmPreviewFromRight() {
        guard warmHost != nil else { return }
        edgeDragging = true
        suppressTermAccessory = false
        primeTermAccessoryForTerminal()
        slideTerminal(toX: view.bounds.width)
        view.bringSubviewToFront(term)
        view.bringSubviewToFront(channelStrip)
        view.bringSubviewToFront(scrollRail)
        view.bringSubviewToFront(newMsgPill)
        view.bringSubviewToFront(voiceOverlay)
        term.isHidden = false
        scrollRail.isHidden = false
        _ = term.becomeFirstResponder()
    }
    private func cancelTerminalSlide(toX x: CGFloat, hideAfter: Bool = false) {
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.slideTerminal(toX: x)
        } completion: { _ in
            self.edgeDragging = false
            if hideAfter {
                _ = self.term.resignFirstResponder()
                self.clearForcedKeyboardOverlap()
                self.term.isHidden = true
                self.scrollRail.isHidden = true
                self.hideNewMsgPill()
                _ = self.becomeFirstResponder()
            }
            self.layoutTerm()
        }
    }
    private func showTerminalViewSlidingIn() {
        suppressTermAccessory = false
        primeTermAccessoryForTerminal()
        if !edgeDragging { slideTerminal(toX: view.bounds.width) }
        view.bringSubviewToFront(term)
        view.bringSubviewToFront(channelStrip)
        view.bringSubviewToFront(scrollRail)
        view.bringSubviewToFront(newMsgPill)
        view.bringSubviewToFront(voiceOverlay)
        term.isHidden = false
        scrollRail.isHidden = false
        _ = term.becomeFirstResponder()
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.slideTerminal(toX: 0)
        } completion: { _ in
            self.edgeDragging = false
            self.primeTermAccessoryForTerminal()
            self.layoutTerm()
        }
    }
    private func showListViewSlidingOut(completion: @escaping () -> Void) {
        voiceOverlay.hide()
        freezeCurrentTermOverlapForSlide()
        edgeDragging = true
        showTerminalBottomCover()
        suppressTermAccessory = true
        updateTermAccessory()
        _ = term.resignFirstResponder()
        let width = view.bounds.width
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.slideTerminal(toX: width)
        } completion: { _ in
            self.term.isHidden = true
            self.scrollRail.isHidden = true
            self.hideNewMsgPill()
            self.terminalBottomCover.isHidden = true
            self.edgeDragging = false
            self.clearForcedKeyboardOverlap()
            self.layoutTerm()
            completion()
        }
    }

    private func showTerminalBottomCover() {
        let base = termBaseFrame()
        terminalBottomCover.frame = CGRect(
            x: term.frame.minX,
            y: base.maxY,
            width: base.width,
            height: max(0, view.bounds.height - base.maxY)
        )
        terminalBottomCover.isHidden = terminalBottomCover.frame.height <= 0
        if !terminalBottomCover.isHidden {
            view.bringSubviewToFront(term)
            view.bringSubviewToFront(channelStrip)
            view.bringSubviewToFront(terminalBottomCover)
            view.bringSubviewToFront(voiceOverlay)
        }
    }

    // MARK: - 键盘(触屏 vkey)避让
    private func registerKeyboardAvoidance() {
        let nc = NotificationCenter.default
        kbFrameObs = nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let v = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let kbInView = self.view.convert(v, from: nil)
            let overlap = max(0, self.view.bounds.maxY - kbInView.minY)
            self.keyboardOverlap = overlap
            if self.shouldShowTermAccessory, overlap > 0 {
                self.cachedKeyBarOverlap = overlap
                self.cachedKeyBarWidth = self.view.bounds.width
            }
            if overlap > 0 || !self.shouldShowTermAccessory { self.clearForcedKeyboardOverlap() }
            self.layoutTerm()
        }
        kbHideObs = nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.keyboardOverlap = 0
            if !self.edgeDragging { self.clearForcedKeyboardOverlap() }
            self.layoutTerm()
        }
    }
    private func layoutTerm() {
        guard let term else { return }
        if edgeDragging { return }
        let f = termBaseFrame()
        term.frame = f
        voiceOverlay.frame = f
        voiceOverlay.reservedBottomInset = terminalBottomVoiceZoneHeight(in: f.height)
        layoutChannelStrip()
        layoutScrollRail()
    }

    private func layoutChannelStrip() {
        guard !channelStrip.isHidden else { return }
        channelStrip.frame = CGRect(
            x: term.frame.minX,
            y: term.frame.maxY - Self.channelStripHeight,
            width: term.frame.width,
            height: Self.channelStripHeight
        )
    }

    func termPage(up: Bool) {
        guard view_ == .terminal, voice.currentState == .idle else { return }
        // Claude Code 对 PageUp/PageDown 不稳定;当前所有 project 类型统一走 tmux 半页滚。
        sendToActivePTY(Data(up ? Self.shiftUpBytes : Self.shiftDownBytes))
        tmuxModeLikely = true
    }

    private static let copyModePollInterval: TimeInterval = 1.5

    /// 仅在自认为 copy-mode 时启动:轮询确认是否已被**外部**退出(硬件 `q` / 直接打字),
    /// app 自己发的 ESC/翻页已在赋值点同步,不靠轮询。非 copy-mode 时零开销(由 tmuxModeLikely.didSet 停掉)。
    private func startCopyModePoll() {
        stopCopyModePoll()
        let t = Timer(timeInterval: Self.copyModePollInterval, repeats: true) { [weak self] _ in
            self?.pollPaneInModeOnce()
        }
        copyModePollTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopCopyModePoll() {
        copyModePollTimer?.invalidate()
        copyModePollTimer = nil
    }

    /// 用既有连接(execCapture,不新建 SSH)读 `#{pane_in_mode}`:"1"=仍在 → 保持;"0"/空(无 tmux)=已退出 → 复原;
    /// nil(连接/exec 瞬时失败)→ 不翻转,避免抖动。sessionGen/session 校验防迟到结果污染新会话。
    private func pollPaneInModeOnce() {
        guard tmuxModeLikely, let ssh = ssh, let session = activeSessionName else { stopCopyModePoll(); return }
        let gen = sessionGen
        Task {
            let out = await ssh.execCapture(SSHSession.tmuxPaneInModeCommand(session))
            await MainActor.run {
                guard self.sessionGen == gen, self.activeSessionName == session, self.tmuxModeLikely else { return }
                guard let out = out else { return }   // 瞬时失败:保持现状,下个周期再试
                if out.trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
                    self.tmuxModeLikely = false        // "0"/空 → 已退出 copy-mode,ESC 复原 + 停轮询
                }
            }
        }
    }

    @objc private func handleTermVoicePress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            voiceArmed = false
            touchVoicePress(pressed: true)   // voiceDown(流式语音)
        case .changed:
            // 手指一离开按压区(上滑过 80% 高度)就**冻结流式刷新**(armedLock),整个上滑过程 overlay
            // 不再被 ASR partial 打乱;过目标带 → 红色 armed;拉回底部(>86%)→ 解冻恢复流式(滞回防抖)。
            guard voice.currentState == .streaming else { return }
            let y = g.location(in: voiceOverlay).y
            let h = voiceOverlay.bounds.height
            guard h > 0 else { return }
            if !voice.armedLock, y < h * 0.80 { voice.armedLock = true }   // 开始上滑 → 冻结
            if voice.armedLock {
                if y > h * 0.86 {                                          // 拉回底部 → 解冻恢复流式
                    voice.armedLock = false
                    voiceArmed = false
                    voice.reshowStreaming()
                } else {
                    let nowArmed = y < voiceOverlay.armZoneBottomY()
                    if nowArmed != voiceArmed {
                        voiceArmed = nowArmed
                        if nowArmed {
                            voiceOverlay.showArmed(text: voice.currentPartial ?? "")
                            keyHaptic.impactOccurred()
                        } else {
                            voiceOverlay.show(status: "🎤 聆听中…", text: voice.currentPartial ?? "")   // 回白带(冻结)
                        }
                    }
                }
            }
        case .ended:
            if voiceArmed { voiceArmed = false; lockVoiceToRecording() }   // 松手在 overlay 上 → 锁录音
            else { voice.armedLock = false; touchVoicePress(pressed: false) }   // 正常松手 → voiceUp(解冻)
        case .cancelled, .failed:
            voiceArmed = false
            voice.armedLock = false
            touchVoicePress(pressed: false)
        default:
            break
        }
    }

    /// 终端触摸分区:仅保留**底部语音热区**(滚动改由右缘拨轮 scrollRail 接管,不再点屏翻页)。
    private func terminalTouchZone(at p: CGPoint, height: CGFloat) -> TerminalTouchZone {
        guard height > 0 else { return .none }
        return p.y >= height * 13 / 15 ? .voice : .none
    }

    private func terminalBottomVoiceZoneHeight(in height: CGFloat) -> CGFloat {
        max(0, height * 2 / 15)
    }

    private func touchVoicePress(pressed: Bool) {
        if pressed {
            keyHaptic.prepare(); keyHaptic.impactOccurred()
        }
        voiceKeyAction(pressed: pressed)
    }

    // MARK: - App foreground → refetch status(列表态)
    private func registerForegroundObserver() {
        foregroundObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MeetingStore.shared.processPending()   // 后台收到的录音(独立于 host)→ 前台即开始转写
            guard (self.view_ == .list || self.view_ == .home), !self.hosts.isEmpty else { return }
            self.refreshManifests()                                    // 快路径:列表/Home 状态即时刷新
            if self.hosts.contains(where: { !$0.basePath.isEmpty }) { self.runTriageRound() }   // 语义分诊一轮
        }
        meetingObs = NotificationCenter.default.addObserver(
            forName: .meetingStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.pushHome() }   // 录音任务状态变 → 刷 Home(off-screen 也刷)
    }

    // MARK: - Valet "Open in" import → reload list (SPEC §8)
    /// 列表态齿轮 → 「管理 Host」(滑动删除)。删除是改本地配置 + 私钥,服务器不受影响。
    @objc func presentHostManager() {
        guard view_ == .list else { return }
        let mgr = HostManagerVC(hosts: hosts)
        mgr.onDone = { [weak self] changed in if changed { self?.reloadHostsAfterDelete() } }
        let nav = UINavigationController(rootViewController: mgr)
        present(nav, animated: true)
    }

    /// 删除 host 后回灌:重读 hosts、清状态/保活/语音上下文(被删的可能正是活动身份),重建列表。
    private func reloadHostsAfterDelete() {
        hosts = HostStore.loadHosts()
        statusByHost = [:]; reachable = nil; probedHosts = []
        triageItems = nil
        voice.shutdown(); applyVoiceContext(nil)
        closeWarm()
        NSLog("[VC] reloadHostsAfterDelete: now \(hosts.count) hosts")
        AgentLog.info("config", "hosts reloaded after delete count=\(hosts.count)")
        deckList.setEmptyText(hosts.isEmpty ? "暂无 host\n\nAirDrop 一个 .xrhosts 配置导入" : nil)
        deckList.setSections(buildSections())
        if !hosts.isEmpty { refreshManifests() }
    }

    func reloadHostsAfterImport(_ result: HostStore.ImportResult) {
        NSLog("[VC] reloadHostsAfterImport: mode=\(result.mode) hosts=\(result.hosts) asr=\(result.asr)")
        AgentLog.info("config", "imported mode=\(result.mode) hosts=\(result.hosts) asr=\(result.asr)")
        hosts = HostStore.loadHosts()
        statusByHost = [:]; reachable = nil; probedHosts = []
        triageItems = nil                 // host 变了 → 旧 digest 失效
        fleetTriage.reloadConfig()        // 可能导入了 correction.json(判官凭证)
        if result.asr, let creds = AsrCreds.load() {
            voice.asr = VolcAsr(creds: creds)
            NSLog("[VC] ASR creds imported → VolcAsr(resource=\(creds.resourceId))")
            AgentLog.info("config", "ASR credentials loaded resource=\(creds.resourceId)")
        }
        // 导入会改 hosts → 旧的活动/保活终端身份可能失效,统一关掉。
        voice.shutdown(); applyVoiceContext(nil)
        closeWarm()
        if view_ != .list { view_ = .list; showListView() }
        nativeToast(importToast(result))
        deckList.setEmptyText(hosts.isEmpty ? "暂无 host\n\nAirDrop 一个 .xrhosts 配置导入" : nil)
        deckList.setSections(buildSections())
        if !hosts.isEmpty { refreshManifests() }
    }
    private func importToast(_ r: HostStore.ImportResult) -> String {
        switch r.mode {
        case .asrOnly: return "ASR 凭证已导入"
        case .append:  return "导入成功:追加 \(r.hosts) host" + (r.asr ? " + ASR" : "")
        case .replace: return "导入成功:\(r.hosts) host" + (r.asr ? " + ASR" : "")
        }
    }
    func reportImportFailure(_ message: String) {
        NSLog("[VC] import failure: \(message)")
        AgentLog.error("config", "import failed: \(message)")
        nativeToast("导入失败:\(message)")
    }

    /// 原生 toast(底部短暂浮现的胶囊,自动消失)。
    private func nativeToast(_ s: String) {
        let lbl = PaddingLabel()
        lbl.text = s
        lbl.font = .systemFont(ofSize: 14, weight: .medium)
        lbl.textColor = .white
        lbl.backgroundColor = UIColor(white: 0.1, alpha: 0.95)
        lbl.layer.cornerRadius = 10; lbl.clipsToBounds = true
        lbl.numberOfLines = 0; lbl.textAlignment = .center
        lbl.alpha = 0
        lbl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lbl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            lbl.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        UIView.animate(withDuration: 0.25, animations: { lbl.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.4, delay: 1.8, options: []) { lbl.alpha = 0 } completion: { _ in lbl.removeFromSuperview() }
        }
    }

    // MARK: - 上滑锁定录音 → 自动转写 → 委托当前 subproject

    /// 松手时手指在 overlay 上 → 锁进录音态(VoiceController 继续采集 + tee WAV;overlay 变录音 UI)。
    private func lockVoiceToRecording() {
        voiceKeyHeld = false               // 防 overlay 的 onVoicePress(false) 再触发 voiceUp
        voice.armedLock = false
        voice.lockToRecording()
        voiceOverlay.showRecording()
        view.bringSubviewToFront(voiceOverlay)
        keyHaptic.impactOccurred()
        // 锁屏/灵动岛录音状态(#23 P2)。projectName = 当前 subproject(投递目标)。
        let pname = activeSessionName.flatMap { s in
            activeHostConfig?.projects.first(where: { $0.session == s })?.name ?? s
        }
        RecordingLiveActivity.start(projectName: pname)
    }

    private func finishVoiceRecording() {
        RecordingLiveActivity.end()
        let file = voice.stopRecording()
        voiceOverlay.hide()
        guard let file else { return }
        persistAndProcessRecording(file: file)
    }

    private func cancelVoiceRecording() {
        RecordingLiveActivity.end()
        voice.cancelRecording()
        voiceOverlay.hide()
    }

    /// 录好的 WAV → **先落盘入收件箱(持久,不丢)**,写自动投递目标 = 当前 subproject,随即在后台
    /// 转写 + 投递(走 MeetingStore;失败留在 Home「待处理」可重试)。非阻塞:给一句 toast 就放手回终端。
    /// 这正是 #23 的要点:长录音哪怕中途失败,原始文件也已落盘,绝不凭空消失。
    private func persistAndProcessRecording(file: URL) {
        let target: RecordingMeta.Target?
        if let h = activeHostConfig, let session = activeSessionName {
            let pname = h.projects.first(where: { $0.session == session })?.name ?? session
            target = .init(hostName: h.name, session: session, projectName: pname)
        } else {
            target = nil   // 没有当前 subproject:仍落盘转写,停在「待投递」,稍后在 Home 手动委托
        }
        do {
            _ = try MeetingStore.shared.ingestRecording(wav: file, target: target)
            try? FileManager.default.removeItem(at: file)   // 已拷进收件箱,临时文件可删
            nativeToast(target.map { "录音已保存,正在转写并交给「\($0.projectName)」…" }
                        ?? "录音已保存,正在转写(稍后在 Home 委托)")
        } catch {
            // 收件箱不可用(App Group 异常):别删临时文件(至少本进程还在),阻塞 HUD 明确报错。
            AgentLog.error("meeting", "ingest recording failed: \(error)")
            showRecordingHUD("录音保存失败:\(error)", done: true, ok: false)
        }
        pushHome()
    }

    /// 录音转写期间的全屏阻塞 HUD:处理中转圈(吞触摸,防误触);完成变 ✓/✗,点一下或 2.5s 自动收起。
    private func showRecordingHUD(_ text: String, done: Bool, ok: Bool) {
        recordingHUD?.removeFromSuperview()
        let dim = UIView(frame: view.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor(white: 0, alpha: 0.62)

        let card = UIView()
        card.backgroundColor = UIColor(white: 0.1, alpha: 0.97)
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(card)

        let top: UIView
        if done {
            let iv = UIImageView(image: UIImage(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill"))
            iv.tintColor = ok ? .systemGreen : .systemRed
            iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)
            top = iv
        } else {
            let spin = UIActivityIndicatorView(style: .large)
            spin.color = .white; spin.startAnimating()
            top = spin
        }
        top.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = text; label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.numberOfLines = 0; label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(top); card.addSubview(label)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: dim.leadingAnchor, constant: 40),
            card.trailingAnchor.constraint(lessThanOrEqualTo: dim.trailingAnchor, constant: -40),
            top.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            top.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
        view.addSubview(dim)
        recordingHUD = dim

        if done {   // 处理中不让收起(卡住);完成后点一下 / 2.5s 自动收
            dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissRecordingHUD)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak dim] in
                if self?.recordingHUD === dim { self?.dismissRecordingHUD() }
            }
        }
    }

    @objc private func dismissRecordingHUD() {
        recordingHUD?.removeFromSuperview()
        recordingHUD = nil
    }

    // MARK: - Hardware keyboard detection (SPEC §6.1)
    private func registerKeyboardObservers() {
        kbConnectObs = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            NSLog("[VC] GCKeyboard connected")
            self?.attachKeyHandler()
            self?.updateTermAccessory()   // 终端:卸掉触屏 vkey
            self?.clearForcedKeyboardOverlap()
            self?.layoutTerm()
        }
        kbDisconnectObs = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            NSLog("[VC] GCKeyboard disconnected")
            self?.voiceKeyHeld = false
            if self?.view_ == .terminal { self?.primeTermAccessoryForTerminal() }
            else { self?.updateTermAccessory() }
            self?.layoutTerm()
        }
        attachKeyHandler()
    }
    private func attachKeyHandler() {
        guard let kb = GCKeyboard.coalesced else { return }
        kb.handlerQueue = .main
        kb.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            if keyCode == .F1 { self?.voiceKeyAction(pressed: pressed) }
            else if keyCode == .F2 { self?.backKeyAction(pressed: pressed) }
        }
    }

    // MARK: - UIPress 主路由:硬件键冒泡到 VC(列表态;终端态由 SwiftTerm 收键)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handlePresses(presses, pressed: true) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handlePresses(presses, pressed: false) { return }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        _ = handlePresses(presses, pressed: false)
        super.pressesCancelled(presses, with: event)
    }
    override var canBecomeFirstResponder: Bool { true }

    /// 硬件键:F1/F2 两态都拦;列表态方向键/Enter → 原生列表导航(deckList);终端态键归 SwiftTerm,不经这里。
    private func handlePresses(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var handled = false
        for p in presses {
            guard let key = p.key else { continue }
            switch key.keyCode {
            case .keyboardF1: voiceKeyAction(pressed: pressed); handled = true
            case .keyboardF2: backKeyAction(pressed: pressed); handled = true
            default:
                guard pressed, view_ == .list else { break }
                switch key.keyCode {
                case .keyboardDownArrow:                    deckList.moveSelection(1);  handled = true
                case .keyboardUpArrow:                      deckList.moveSelection(-1); handled = true
                case .keyboardReturnOrEnter, .keypadEnter:  deckList.openSelected();    handled = true
                default: break
                }
            }
        }
        return handled
    }

    // MARK: - SwiftTerm delegate(终端 → app)
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sendToActivePTY(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { ssh?.resize(cols: newCols, rows: newRows) }
    func scrolled(source: TerminalView, position: Double) {
        if position >= 0.999 { newMsgCount = 0; hideNewMsgPill() }   // 回到底 → 清新消息提示 + 恢复跟随
    }

    // MARK: - 右缘无极拨轮(TerminalScrollRailDelegate)+ 滚动锁/新消息药丸

    private func layoutScrollRail() {
        guard let term else { return }
        positionRail(in: term.frame)
    }

    private func positionRail(in f: CGRect) {
        let voiceH = terminalBottomVoiceZoneHeight(in: f.height)
        let w = TerminalScrollRail.hitWidth
        scrollRail.frame = CGRect(x: f.maxX - w, y: f.minY, width: w, height: max(0, f.height - voiceH))
        let rows = max(1, term?.getTerminal().rows ?? 24)
        scrollRail.lineHeight = max(8, f.height / CGFloat(rows))
        layoutNewMsgPill(in: f, voiceH: voiceH)
    }

    private func layoutNewMsgPill(in f: CGRect, voiceH: CGFloat) {
        newMsgLabel.sizeToFit()
        let w = max(110, newMsgLabel.bounds.width + 28)
        let h: CGFloat = 32
        newMsgPill.frame = CGRect(x: f.midX - w / 2, y: f.maxY - voiceH - h - 12, width: w, height: h)
        newMsgLabel.frame = newMsgPill.bounds
    }

    /// rail 回调:把"滚 N 行"翻译成本地 SwiftTerm 滚动 / tmux 深历史接力。
    /// `lines>0`=朝历史(上/旧),`<0`=朝最新(下/新)。返回 false=到硬边(rail 停惯性)。
    @discardableResult
    func terminalScrollRail(_ rail: TerminalScrollRail, scrollLines lines: Int, inertia: Bool) -> Bool {
        guard view_ == .terminal, !term.isHidden, voice.currentState == .idle else { return false }
        if lines > 0 {                       // 朝历史
            if tmuxModeLikely { return handoffScroll(up: true) }            // 已在 copy-mode → 继续翻深历史
            if term.canScroll, term.scrollPosition > 0 {
                term.scrollUp(lines: lines)
                updatePinAfterScroll()
                return true
            }
            // 本地到顶(或无本地缓冲) → tmux 深历史接力(仅 tmux 类 project,且非惯性,避免狂发 SSH)
            if activeProjectType?.isAiAgent == true, !inertia { return handoffScroll(up: true) }
            return false                     // 纯 SSH 到顶 / 惯性到顶 → 停
        } else if lines < 0 {                // 朝最新
            if tmuxModeLikely { return handoffScroll(up: false) }
            if term.canScroll {
                term.scrollDown(lines: -lines)
                updatePinAfterScroll()
                return true
            }
            return false
        }
        return true
    }

    func terminalScrollRailDidBegin(_ rail: TerminalScrollRail) {}
    func terminalScrollRailDidEnd(_ rail: TerminalScrollRail) {}

    /// tmux 深历史接力:限速发 Shift+↑/↓(复用 termPage,内置置 tmuxModeLikely + copy-mode 轮询)。
    /// 首次进 copy-mode 给一震 + 一闪提示。返回 true=视为已消费(吞掉限速期内的多余调用,保持手势连续)。
    @discardableResult
    private func handoffScroll(up: Bool) -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastHandoffAt >= Self.handoffMinInterval else { return true }
        lastHandoffAt = now
        if up, !tmuxModeLikely {
            keyHaptic.prepare(); keyHaptic.impactOccurred()
            flashHistoryHint()
        }
        termPage(up: up)
        return true
    }

    private func updatePinAfterScroll() {
        if !term.canScroll || term.scrollPosition >= 0.999 { newMsgCount = 0; hideNewMsgPill() }
    }

    private func showNewMsgPill() {
        newMsgLabel.text = "▼ 新消息"
        if let term { layoutNewMsgPill(in: term.frame, voiceH: terminalBottomVoiceZoneHeight(in: term.frame.height)) }
        view.bringSubviewToFront(newMsgPill)
        guard newMsgPill.isHidden else { return }
        newMsgPill.isHidden = false
        newMsgPill.alpha = 0
        UIView.animate(withDuration: 0.2) { self.newMsgPill.alpha = 1 }
    }

    private func hideNewMsgPill() {
        guard !newMsgPill.isHidden else { return }
        UIView.animate(withDuration: 0.18, animations: { self.newMsgPill.alpha = 0 }) { _ in
            self.newMsgPill.isHidden = true
        }
    }

    @objc private func jumpToLatest() {
        if tmuxModeLikely {                  // 在 tmux 深历史 → ESC 退 copy-mode 回到底
            tmuxModeLikely = false
            sendToActivePTY(Data([27]))
        } else {
            term.scroll(toPosition: 1)       // 本地缓冲 → 直接到底
        }
        newMsgCount = 0
        hideNewMsgPill()
        keyHaptic.prepare(); keyHaptic.impactOccurred()
    }

    /// 进 tmux 深历史时一闪而过的提示(非常驻),提醒按 Esc 可退。
    private func flashHistoryHint() {
        guard let term else { return }
        let l = UILabel()
        l.text = "历史模式 · Esc 退"
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = UIColor(white: 0, alpha: 0.62)
        l.textAlignment = .center
        l.sizeToFit()
        let w = l.bounds.width + 24, h = l.bounds.height + 12
        l.frame = CGRect(x: term.frame.midX - w / 2, y: term.frame.minY + 44, width: w, height: h)
        l.layer.cornerRadius = h / 2
        l.clipsToBounds = true
        l.alpha = 0
        view.addSubview(l)
        UIView.animate(withDuration: 0.15, animations: { l.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.4, delay: 0.8, options: []) { l.alpha = 0 } completion: { _ in l.removeFromSuperview() }
        }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}

    // MARK: - TerminalHostKeyHandler(SwiftTerm 子类拦下的 app 专用键)
    func termVoiceKey(down: Bool) { voiceKeyAction(pressed: down) }
    func termBackKey() { backToList() }
    func termSend(bytes: [UInt8]) { sendToActivePTY(Data(bytes)) }
    func termVoiceActive() -> Bool { voice.currentState != .idle }
    func termVoiceEnter() -> Bool { voice.onEnter() }
    func termVoiceEsc() -> Bool { voice.onEsc() }

    // MARK: - 触屏 vkey
    private func updateTermAccessory() {
        guard let term, let keyBar else { return }
        keyBar.frame.size.width = view.bounds.width
        term.inputAccessoryView = (!suppressTermAccessory && shouldShowTermAccessory) ? keyBar : nil
        if term.isFirstResponder { term.reloadInputViews() }
    }
    private func handleKeyBarAction(_ a: TerminalKeyAction) {
        if a == .delWord {
            let now = CACurrentMediaTime()
            if now - lastDelWordHapticAt > 0.25 {
                lastDelWordHapticAt = now
                keyHaptic.prepare(); keyHaptic.impactOccurred()
            }
        } else {
            keyHaptic.prepare(); keyHaptic.impactOccurred()
        }
        switch a {
        case .up:       sendToActivePTY(Data(arrowBytes(0x41)))
        case .down:     sendToActivePTY(Data(arrowBytes(0x42)))
        case .right:    sendToActivePTY(Data(arrowBytes(0x43)))
        case .left:     sendToActivePTY(Data(arrowBytes(0x44)))
        case .enter:    if !voice.onEnter() { sendToActivePTY(Data([13])) }
        case .esc:
            if !voice.onEsc() {
                tmuxModeLikely = false
                sendToActivePTY(Data([27]))
            }
        case .shiftTab: sendToActivePTY(Data([0x1b, 0x5b, 0x5a]))
        case .ctrlC:    sendToActivePTY(Data([0x03]))
        case .ctrlB:    sendToActivePTY(Data([0x02]), expectOutput: false)
        case .delWord:  sendToActivePTY(Data([0x17]))
        case .paste:    handlePasteAction()
        }
    }
    private func arrowBytes(_ final: UInt8) -> [UInt8] {
        let app = term.getTerminal().applicationCursor
        return [0x1b, app ? 0x4f : 0x5b, final]
    }

    // MARK: - 粘贴(文字直写 PTY;图片经 SFTP 传远端再插路径)
    /// 剪贴板有图 → 走图片上传;否则有文字 → 直接粘贴文字。两者皆空 = 无操作(已震动反馈)。
    private func handlePasteAction() {
        let pb = UIPasteboard.general
        if pb.hasImages, let img = pb.image, let payload = imageDataForPaste(img) {
            pasteImage(payload.data, ext: payload.ext)
        } else if let s = pb.string, !s.isEmpty {
            pasteText(s)
        } else {
            AgentLog.debug("ui", "paste: clipboard empty/unsupported")
        }
    }

    /// 文字粘贴:对齐 SwiftTerm 自身 paste —— 终端开了 bracketed paste(Claude Code 等)就包 start/end,
    /// 内容原样发(多行不会被逐行回车提前提交);否则裸发。空字符串忽略。
    private func pasteText(_ s: String) {
        guard !s.isEmpty else { return }
        var bytes = Array(s.utf8)
        if term.getTerminal().bracketedPasteMode {
            bytes = EscapeSequences.bracketedPasteStart + bytes + EscapeSequences.bracketedPasteEnd
        }
        sendToActivePTY(Data(bytes))
    }

    /// 截图等无损优先 PNG;PNG 超 ~4.5MB(Claude Code 单图上限 5MB,留余量)或失败 → 回退 JPEG。
    /// 扩展名随实际格式(Claude Code 按 .png/.jpg/.jpeg/.gif/.webp 扩展名识别为视觉图片)。
    /// 相册原图可能很大,先按长边 2000px 降采样(Claude 视觉本就 ~1568px 重采样,过大无益且易超限)。
    private func imageDataForPaste(_ img: UIImage) -> (data: Data, ext: String)? {
        let scaled = Self.downscaledForVision(img)
        if let p = scaled.pngData(), p.count <= 4_500_000 { return (p, "png") }
        if let j = scaled.jpegData(compressionQuality: 0.82) { return (j, "jpg") }
        if let p = scaled.pngData() { return (p, "png") }   // JPEG 也失败时的兜底
        return nil
    }

    /// 长边 > maxSide 像素才降采样;否则原样返回(截图通常已小于阈值,保持无损)。
    private static func downscaledForVision(_ img: UIImage) -> UIImage {
        let maxSide: CGFloat = 2000
        let pxW = img.size.width * img.scale, pxH = img.size.height * img.scale
        let longest = max(pxW, pxH)
        guard longest > maxSide, longest > 0 else { return img }
        let ratio = maxSide / longest
        let target = CGSize(width: (pxW * ratio).rounded(), height: (pxH * ratio).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1   // 1x 渲染 → 点尺寸即像素尺寸,编码出的就是 target 像素
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 图片粘贴:SFTP 上传远端临时文件(复用现有连接),成功后把远端绝对路径 + 空格插进终端
    /// (不回车 —— 用户可再补语音/文字说明后自行 Enter,Claude Code 据路径读图)。
    private func pasteImage(_ data: Data, ext: String) {
        guard let ssh else {
            setChannelStrip(.disconnected, "SSH 通道已断开，返回列表重开此 project")
            return
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = "paste-\(stamp).\(ext)"
        setChannelStrip(.checking, "粘贴图片上传中…(\(data.count / 1024)KB)")
        let gen = sessionGen
        Task {
            let path = await ssh.uploadToRemoteTemp(data, filename: name)
            await MainActor.run {
                guard self.view_ == .terminal, self.sessionGen == gen, self.ssh != nil else { return }
                if let path {
                    self.setChannelStrip(.hidden)
                    self.pasteText(path + " ")
                } else {
                    self.setChannelStrip(.disconnected, "图片粘贴失败，请重试")
                }
            }
        }
    }

    // MARK: - 物理键 action(两条路由共用,幂等)
    private func voiceKeyAction(pressed: Bool) {
        guard view_ == .terminal else { return }
        if pressed {
            if !voiceKeyHeld {
                voiceKeyHeld = true
                ensureMicThenRecord()
                voice.voiceDown(lang: "zh")
                warnIfTmuxCopyModeForVoice()
            }
        } else if voiceKeyHeld {
            voiceKeyHeld = false; voice.voiceUp(lang: "zh")
        }
    }
    private func backKeyAction(pressed: Bool) {
        if !pressed, view_ == .terminal { backToList() }
    }

    // MARK: - Voice input
    private func setupVoice() {
        let asr: Asr
        if let creds = AsrCreds.load() {
            asr = VolcAsr(creds: creds)
            NSLog("[VC] ASR = VolcAsr(resource=\(creds.resourceId))")
        } else {
            asr = MockAsr()
            NSLog("[VC] ASR = MockAsr (no asr.json creds)")
        }
        voice = VoiceController(
            asr: asr,
            showOverlay: { [weak self] status, text in self?.voiceOverlay.show(status: status, text: text) },
            showCorrecting: { [weak self] text in self?.voiceOverlay.showCorrecting(text: text) },
            hideOverlay: { [weak self] in self?.voiceOverlay.hide() }
        )
        voice.inject = { [weak self] data in self?.sendToActivePTY(data) }
        voice.recorder = AudioCapture()   // 同步建好,否则首次 voiceDown recorder 还 nil

        // LLM 上下文纠错(issue #16):配了 correction.json 才接,否则纠错关闭(= 改造前行为)。
        if let cc = CorrectionConfig.load(), let corrector = OpenAiCompatCorrector(config: cc) {
            voice.corrector = corrector
            NSLog("[VC] voice correction = \(cc.model)")   // 不打 key
            AgentLog.info("voice", "correction = \(cc.model)")
        } else {
            NSLog("[VC] voice correction = off (no correction.json)")
        }
    }

    private func warnIfTmuxCopyModeForVoice() {
        guard activeProjectType?.isAiAgent == true,
              let h = activeHostConfig,
              let session = activeSessionName,
              ssh != nil else { voice.setInputWarning(nil); return }
        let via = activeViaConfig
        let gen = sessionGen
        let likely = tmuxModeLikely
        if likely { voice.setInputWarning(Self.copyModeVoiceWarning) }
        Task {
            let inMode = await TmuxModeProbe.paneInMode(host: h, via: via, session: session)
            await MainActor.run {
                guard self.sessionGen == gen,
                      self.activeSessionName == session,
                      self.ssh != nil,
                      self.voice.currentState != .idle else { return }
                if inMode == true {
                    self.tmuxModeLikely = true
                    self.voice.setInputWarning(Self.copyModeVoiceWarning)
                    AgentLog.info("terminal", "voice warns tmux copy-mode session=\(session)")
                } else if inMode == false {
                    self.tmuxModeLikely = false
                    self.voice.setInputWarning(nil)
                } else if likely {
                    self.voice.setInputWarning(Self.copyModeVoiceWarning)
                }
            }
        }
    }
    private func ensureMicThenRecord() {
        guard !micRequested else { return }
        micRequested = true
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            NSLog("[VC] mic permission = \(granted ? "granted" : "DENIED — 语音录不到音")")
        }
    }
    private func applyVoiceContext(_ project: ProjectConfig?) {
        activeProjectType = project?.type
        voice.terminalContext = nil   // 纠错的 tmux 背景来源:连上后由 onConnected 设;切 project/回列表先清
        if let project {
            voice.hotwords = Hotwords.merge(project.hotwords)
            voice.voiceMarkerEnabled = project.type.isAiAgent
            voice.projectName = project.name
            voice.sessionType = project.type.rawValue
        } else {
            voice.hotwords = Hotwords.base
            voice.voiceMarkerEnabled = false
            voice.projectName = ""
            voice.sessionType = "ssh"
        }
    }

    private func writeToTerm(_ s: String) { term.feed(text: s) }

    #if DEBUG
    /// Self-verification levers(launch-arg gated,生产无效)。
    private func applyDebugLevers() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-voiceDemo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onOpenProject(host: "demo", session: "demo", name: "voice-demo", type: "claude")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.voice.voiceDown(lang: "zh")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.voice.voiceUp(lang: "zh") }
                }
            }
        }
        if args.contains("-openMock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.onOpenProject(host: "demo", session: "demo", name: "mock", type: "claude")
            }
        }
        if let i = args.firstIndex(of: "-importConfigPath"), i + 1 < args.count {
            do { reloadHostsAfterImport(try HostStore.importConfig(from: URL(fileURLWithPath: args[i + 1]))) }
            catch { reportImportFailure("\(error)") }
        }
    }

    private var didAutoOpen = false
    private func maybeAutoOpen() {
        guard !didAutoOpen, view_ == .list || view_ == .home else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-autoOpenSession"), i + 1 < args.count else { return }
        let session = args[i + 1]
        let host = (args.firstIndex(of: "-autoOpenHost").map { args[$0 + 1] }) ?? hosts.first?.name ?? ""
        guard let h = hosts.first(where: { $0.name == host }),
              let p = h.projects.first(where: { $0.session == session }) else { return }
        didAutoOpen = true
        onOpenProject(host: host, session: p.session, name: p.name, type: p.type.rawValue)
    }
    #endif

    deinit {
        triageTimer?.invalidate()
        for o in [kbConnectObs, kbDisconnectObs, foregroundObs, meetingObs, kbFrameObs, kbHideObs] {
            if let o { NotificationCenter.default.removeObserver(o) }
        }
    }
}

/// 带内边距的 UILabel(原生 toast 用)。
final class PaddingLabel: UILabel {
    private let inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}
