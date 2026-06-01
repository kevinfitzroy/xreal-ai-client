import UIKit
import GameController
import AVFoundation
import SwiftTerm

/// Core-loop controller. Mirrors Android's MainActivity:
///   hosts.json → Agent Deck list → openProject → SSH(ed25519) PTY terminal → back.
///
/// **架构(2026-06 iOS 全面原生化)**:列表态 = **原生 `DeckListView`(UITableView)**,标准 iPhone 体验
/// (点 cell 进 project、下拉刷新、滑动、状态栏可见);终端态 = **原生 SwiftTerm `TerminalView`**(沉浸式全屏)。
/// WKWebView/index.html 已退出 iOS(只留 Android)。两个 view 叠放,按 view_ 显隐切换;
/// 物理键(8BitDo)经 pressesBegan:列表态 → deckList 选择/打开;终端态 → SwiftTerm 直接编码;F1/F2 拦截。
final class TerminalViewController: UIViewController, TerminalViewDelegate, TerminalHostKeyHandler, UIGestureRecognizerDelegate {

    // 沉浸式全屏**只在终端态**(AR 眼镜):隐藏状态栏 + home indicator。列表态恢复标准 iOS chrome。
    override var prefersStatusBarHidden: Bool { view_ == .terminal }
    override var prefersHomeIndicatorAutoHidden: Bool { view_ == .terminal }

    // 原生列表(替代 WKWebView/index.html)。
    private let deckList = DeckListView(frame: .zero)
    // 原生终端(SwiftTerm):终端态渲染 + 键盘;列表态隐藏。
    private var term: TerminalHostView!
    // 语音预览浮层(原生)。
    private let voiceOverlay = VoiceOverlayView()
    private let pageCueView = UIImageView()
    private let terminalBottomCover = UIView()
    // 触屏虚拟键盘(原生),无硬件键盘时挂为终端的 inputAccessoryView。
    private var keyBar: TerminalKeyBar!
    // 按键震动(VC 主窗口上下文触发;keybar 在键盘窗口里触发观测不到震动)。
    private let keyHaptic = UIImpactFeedbackGenerator(style: .light)
    // 键盘(触屏 vkey)避让:终端高度缩到键盘顶之上。
    private var keyboardOverlap: CGFloat = 0
    private var forcedKeyboardOverlap: CGFloat?
    private var cachedKeyBarOverlap: CGFloat = 0
    private var cachedKeyBarWidth: CGFloat = 0
    private var suppressTermAccessory = false
    private var kbFrameObs: NSObjectProtocol?
    private var kbHideObs: NSObjectProtocol?
    private var edgeDragging = false
    private weak var termPageTap: UITapGestureRecognizer?
    private weak var termVoicePress: UILongPressGestureRecognizer?
    private weak var termReturnPan: UIPanGestureRecognizer?
    private weak var listResumePan: UIPanGestureRecognizer?

    private enum ViewState { case list, terminal }
    private enum TerminalTouchZone { case pageUp, pageDown, voice, none }
    private var view_ = ViewState.list

    // Active PTY session(终端态活动;**列表态保活中也非 nil**,见 iOS.7)。
    private var ssh: SSHSession?
    private var openSeq = 0      // fast open→back→open mustn't bind a stale PTY
    private var sessionGen = 0   // late output chunk from a closed session must not paint a new one
    // iOS.7 最近终端保活:backToList 不关 ssh,保留 SwiftTerm 绘制 + 后台继续喂输出;超时才真关。
    // 开同一 project / 列表右缘滑 = 滑回(已连接则瞬间,连接中则回到连接页);开不同 project = 关旧连新。
    // warm* = 当前/保活终端身份。
    private var warmHost: String?
    private var warmSession: String?
    private var keepWarmWork: DispatchWorkItem?
    private static let keepWarmSeconds: Double = 90   // 短时间保活;超时关 client(tmux session 服务端仍在)
    private static let listResumeStartFraction: CGFloat = 0.25   // 右侧 75% 区域都可左滑回最近终端

    private var hosts: [HostConfig] = []
    // Live status (SPEC §3). reachable == nil = not yet probed.
    private var statusByHost: [String: [String: SessionState]] = [:]
    private var reachable: Set<String>? = nil
    private var probedHosts: Set<String> = []   // hosts whose probe landed this round (incremental loading)
    private var fetchGen = 0                     // race guard: overlapping refreshManifests

    private var kbConnectObs: NSObjectProtocol?
    private var kbDisconnectObs: NSObjectProtocol?
    private var foregroundObs: NSObjectProtocol?

    // 语音输入(Android VoiceDaemon 的对应)。
    private var voice: VoiceController!
    private var micRequested = false
    private var voiceKeyHeld = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = "项目"
        navigationItem.largeTitleDisplayMode = .always

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

        // 原生终端(SwiftTerm),覆盖在列表之上,默认隐藏,终端态显示。
        TerminalKeyInterceptor.installOnce()   // swizzle pressesBegan 拦 F1/F2 + 语音 Enter/Esc
        let t = TerminalHostView(frame: view.bounds, font: TerminalFonts.terminalFont(size: 13))
        t.autoresizingMask = []   // 高度由 layoutTerm 按触屏 vkey 避让管理
        t.terminalDelegate = self
        t.keyHandler = self
        t.nativeBackgroundColor = .black
        t.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
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
        // terminal 触摸分区(SPEC §6):只按 term.frame 核心显示区切 5 份;vkey/inputAccessoryView 不参与计算。
        let pageTap = UITapGestureRecognizer(target: self, action: #selector(handleTermPageTap(_:)))
        pageTap.cancelsTouchesInView = false
        pageTap.delegate = self
        t.addGestureRecognizer(pageTap)
        self.termPageTap = pageTap
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
                }
            }
        }
        voiceOverlay.onVoicePress = { [weak self] down in self?.touchVoicePress(pressed: down) }
        view.addSubview(voiceOverlay)
        pageCueView.isHidden = true
        pageCueView.alpha = 0
        pageCueView.isUserInteractionEnabled = false
        pageCueView.contentMode = .center
        view.addSubview(pageCueView)
        terminalBottomCover.backgroundColor = .black
        terminalBottomCover.isHidden = true
        view.addSubview(terminalBottomCover)

        setupVoice()

        hosts = HostStore.loadHosts()
        NSLog("[VC] loaded \(hosts.count) hosts from hosts.json")
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
        resumePan.cancelsTouchesInView = false
        view.addGestureRecognizer(resumePan)
        self.listResumePan = resumePan

        #if DEBUG
        applyDebugLevers()
        #endif
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
        if let termPageTap, gestureRecognizer === termPageTap {
            guard view_ == .terminal, !term.isHidden, voice.currentState == .idle else { return false }
            let zone = terminalTouchZone(at: gestureRecognizer.location(in: term), height: term.bounds.height)
            return zone == .pageUp || zone == .pageDown
        }
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
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if let termReturnPan, gestureRecognizer === termReturnPan || otherGestureRecognizer === termReturnPan { return true }
        if let listResumePan, gestureRecognizer === listResumePan || otherGestureRecognizer === listResumePan { return true }
        return false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if view_ == .list { becomeFirstResponder() }   // 列表态 VC 收硬件键 → 列表导航
        // 根 VC 无可 pop,关掉 nav 的左缘返回手势 → 左缘留给我们的"终端回列表"(iOS.6)。
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTerm()
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
            return DeckSection(hostName: h.name, addr: h.addr, up: hostLoading || !unreachable, rows: rows)
        }
    }

    private func pushList() {
        if view_ == .list { deckList.setSections(buildSections()) }
    }

    /// Fetch each host's manifest + status off the main actor (concurrent + per-host timeout in
    /// ManifestFetcher), pushing the list INCREMENTALLY as each host resolves (SPEC §9). `fetchGen`
    /// discards a superseded fetch.
    private func refreshManifests() {
        let snapshot = hosts
        fetchGen += 1
        let gen = fetchGen
        Task {
            let result = await ManifestFetcher.fetch(snapshot) { [weak self] r in
                guard let self, gen == self.fetchGen else { return }
                self.probedHosts.insert(r.host.name)
                self.statusByHost[r.host.name] = r.status
                if r.liveFetched {
                    var reach = self.reachable ?? []
                    if r.reachable { reach.insert(r.host.name) } else { reach.remove(r.host.name) }
                    self.reachable = reach
                }
                self.hosts = self.hosts.map { $0.name == r.host.name ? r.host : $0 }
                self.pushList()
            }
            await MainActor.run {
                guard gen == self.fetchGen else { return }
                self.hosts = result.hosts
                self.statusByHost = result.statusByHost
                self.reachable = result.reachable
                self.probedHosts = Set(result.hosts.map { $0.name })
                self.pushList()
                #if DEBUG
                self.maybeAutoOpen()
                #endif
            }
        }
    }

    // MARK: - Open project → PTY
    private func onOpenProject(host: String, session: String, name: String, type: String) {
        NSLog("[VC] openProject host=\(host) session=\(session)")
        // iOS.7:命中保活终端 → 瞬间滑回原终端(不重连);否则关掉上一个保活终端再连新的。
        if host == warmHost, session == warmSession, ssh != nil { resumeWarm(); return }
        closeWarm()
        let seq = { openSeq += 1; return openSeq }()
        view_ = .terminal
        showTerminalView(clear: true)   // 新连接:清屏

        guard let h = hosts.first(where: { $0.name == host }),
              let p = (h.projects.first(where: { $0.session == session })) else {
            applyVoiceContext(nil)
            writeToTerm("\r\n[no SSH config for \(session)]\r\n")
            return
        }
        warmHost = host; warmSession = session   // 记下当前终端身份(保活用)
        applyVoiceContext(p)
        let jump = h.via.flatMap { vn in hosts.first(where: { $0.name == vn }) }
        let viaNote = jump.map { " ⤳ \($0.name)" } ?? ""
        writeToTerm("连接 \(h.name)\(viaNote) … (\(p.session))\r\n")   // alias, never the real IP

        let gen = { sessionGen += 1; return sessionGen }()
        let s = SSHSession()
        s.onOutput = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.sessionGen == gen else { return }   // late chunk from closed session
                self.term.feed(byteArray: ArraySlice(data))
            }
        }
        s.onClosed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.sessionGen == gen, self.ssh === s else { return }
                NSLog("[VC] PTY dropped gen=\(gen) view=\(self.view_ == .terminal ? "term" : "warm")")
                self.ssh = nil
                self.warmHost = nil; self.warmSession = nil   // 保活终端也断了 → 清理
                self.cancelKeepWarm()
                if self.view_ == .terminal {
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
                    NSLog("[VC] PTY live host=\(h.name) session=\(p.session) view=\(self.view_ == .terminal ? "term" : "warm")")
                    if self.view_ == .terminal {
                        let t = self.term.getTerminal()
                        self.ssh?.resize(cols: t.cols, rows: t.rows)   // 补推当前终端尺寸
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-autoTypeAfterOpen") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.ssh?.send(Data("echo XREAL_OK\n".utf8)) }
                    }
                    #endif
                }
            },
            onFailure: { [weak self] err in
                DispatchQueue.main.async {
                    guard let self, seq == self.openSeq else { return }
                    NSLog("[VC] PTY connect failed: \(err)")
                    if self.warmHost == h.name, self.warmSession == p.session {
                        self.warmHost = nil; self.warmSession = nil
                        self.cancelKeepWarm()
                    }
                    if self.view_ == .terminal {
                        self.writeToTerm("\r\nSSH 连接失败: \(err)\r\n")
                    }
                }
            }
        )
    }

    private func backToList(animated: Bool = false) {
        NSLog("[VC] backToList (keep-warm)")
        voiceKeyHeld = false
        voice.shutdown()
        applyVoiceContext(nil)
        // iOS.7 保活:**不关 ssh**,SwiftTerm 绘制保留、后台继续喂输出;keepWarmSeconds 后超时真关。
        // 列表右缘滑 / 重开同一 project = 瞬间滑回(不重连)。
        if ssh != nil || warmHost != nil { scheduleKeepWarm() }
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
            self?.closeWarm()
        }
        keepWarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepWarmSeconds, execute: work)
    }
    private func cancelKeepWarm() { keepWarmWork?.cancel(); keepWarmWork = nil }
    /// 真正关掉保活终端的 SSH(client 断;tmux session 服务端持久)。bump 计数失活在途连接/迟到输出。
    private func closeWarm() {
        cancelKeepWarm()
        openSeq += 1; sessionGen += 1
        let old = ssh; ssh = nil
        old?.close()
        warmHost = nil; warmSession = nil
    }
    /// 回到最近终端:已连接时瞬间恢复;连接中时回到原连接页,等 onConnected 继续绑定。
    private func resumeWarm(animated: Bool = false) {
        guard warmHost != nil else { return }   // 无保活终端(或已超时/失败清理)→ 不动
        NSLog("[VC] resume warm terminal \(warmHost ?? "")/\(warmSession ?? "")")
        cancelKeepWarm()
        if let h = hosts.first(where: { $0.name == warmHost }),
           let p = h.projects.first(where: { $0.session == warmSession }) { applyVoiceContext(p) }
        view_ = .terminal
        animated ? showTerminalViewSlidingIn() : showTerminalView(clear: false)   // **不清屏**:保留原内容
        let t = term.getTerminal()
        ssh?.resize(cols: t.cols, rows: t.rows)
    }

    // MARK: - 终端/列表 view 切换
    private func showTerminalView(clear: Bool = true) {
        if clear { term.feed(text: "\u{1b}c") }   // 新连接 RIS 全复位;保活滑回**不清屏**(保留原内容)
        suppressTermAccessory = false
        primeTermAccessoryForTerminal()
        slideTerminal(toX: 0)
        view.bringSubviewToFront(term)
        view.bringSubviewToFront(pageCueView)
        view.bringSubviewToFront(voiceOverlay)
        view.bringSubviewToFront(terminalBottomCover)
        term.isHidden = false
        _ = term.becomeFirstResponder()
        navigationController?.setNavigationBarHidden(true, animated: false)  // 终端沉浸:隐藏 nav bar
        setNeedsStatusBarAppearanceUpdate()                                  // + 状态栏 + home indicator
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    private func showListView(reloadList: Bool = true) {
        voiceOverlay.hide()
        pageCueView.isHidden = true
        suppressTermAccessory = true
        updateTermAccessory()
        _ = term.resignFirstResponder()
        clearForcedKeyboardOverlap()
        term.isHidden = true
        terminalBottomCover.isHidden = true
        _ = becomeFirstResponder()      // 列表态 VC 收硬件键 → 列表导航
        if reloadList { pushList() }
        navigationController?.setNavigationBarHidden(false, animated: false) // 列表:恢复 nav bar(大标题)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private var shouldShowTermAccessory: Bool { GCKeyboard.coalesced == nil }

    private func predictedKeyBarOverlap() -> CGFloat {
        guard shouldShowTermAccessory, let keyBar else { return 0 }
        keyBar.frame.size.width = view.bounds.width
        keyBar.setNeedsLayout()
        keyBar.layoutIfNeeded()
        let intrinsic = max(0, keyBar.intrinsicContentSize.height)
        let fallbackSafeBottom = keyBar.safeAreaInsets.bottom > 0 ? 0 : view.safeAreaInsets.bottom
        return intrinsic + fallbackSafeBottom
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
        view.bringSubviewToFront(pageCueView)
        view.bringSubviewToFront(voiceOverlay)
        term.isHidden = false
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
        view.bringSubviewToFront(pageCueView)
        view.bringSubviewToFront(voiceOverlay)
        term.isHidden = false
        _ = term.becomeFirstResponder()
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.slideTerminal(toX: 0)
        } completion: { _ in
            self.edgeDragging = false
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
    }

    /// terminal 触摸分区:上 2/5 → PageUp;中 2/5 → PageDown;底部热区由 `handleTermVoicePress` 接管。
    @objc private func handleTermPageTap(_ g: UITapGestureRecognizer) {
        guard view_ == .terminal else { return }
        let zone = terminalTouchZone(at: g.location(in: term), height: term.bounds.height)
        guard zone == .pageUp || zone == .pageDown else { return }
        keyHaptic.prepare(); keyHaptic.impactOccurred()
        let up = zone == .pageUp
        termPage(up: up)
        showPageCue(up: up)
    }

    func termPage(up: Bool) {
        guard view_ == .terminal, voice.currentState == .idle else { return }
        // Claude/其他全屏 TUI 使用 alternate screen,本地 scrollback 不可用;发 PageUp/Down 让应用自己滚。
        ssh?.send(Data(up ? [0x1b, 0x5b, 0x35, 0x7e] : [0x1b, 0x5b, 0x36, 0x7e]))
    }

    @objc private func handleTermVoicePress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            touchVoicePress(pressed: true)
        case .ended, .cancelled, .failed:
            touchVoicePress(pressed: false)
        default:
            break
        }
    }

    private func terminalTouchZone(at p: CGPoint, height: CGFloat) -> TerminalTouchZone {
        // `height` 来自 term.bounds.height,也就是已经排除 vkey 后的 terminal 核心高度。
        guard height > 0 else { return .none }
        if p.y < height * 2 / 5 { return .pageUp }
        if p.y < height * 4 / 5 { return .pageDown }
        if p.y >= height * 13 / 15 { return .voice }
        return .none
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

    private func showPageCue(up: Bool) {
        let zoneY = term.frame.minY + (up ? 0 : term.bounds.height * 2 / 5)
        let zoneFrame = CGRect(x: term.frame.minX, y: zoneY, width: term.frame.width, height: term.bounds.height * 2 / 5)
        let config = UIImage.SymbolConfiguration(pointSize: 58, weight: .semibold)
        pageCueView.image = UIImage(systemName: up ? "arrow.up" : "arrow.down", withConfiguration: config)
        pageCueView.tintColor = UIColor.white.withAlphaComponent(0.64)
        pageCueView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        pageCueView.frame = zoneFrame
        pageCueView.layer.borderWidth = 1 / UIScreen.main.scale
        pageCueView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        pageCueView.layer.removeAllAnimations()
        pageCueView.isHidden = false
        pageCueView.alpha = 0
        view.bringSubviewToFront(pageCueView)
        view.bringSubviewToFront(voiceOverlay)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.pageCueView.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.36, delay: 0.38, options: [.curveEaseIn, .allowUserInteraction]) {
                self.pageCueView.alpha = 0
            } completion: { _ in
                self.pageCueView.isHidden = true
            }
        }
    }

    // MARK: - App foreground → refetch status(列表态)
    private func registerForegroundObserver() {
        foregroundObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.view_ == .list, !self.hosts.isEmpty { self.refreshManifests() }
        }
    }

    // MARK: - Valet "Open in" import → reload list (SPEC §8)
    func reloadHostsAfterImport(_ result: HostStore.ImportResult) {
        NSLog("[VC] reloadHostsAfterImport: mode=\(result.mode) hosts=\(result.hosts) asr=\(result.asr)")
        hosts = HostStore.loadHosts()
        statusByHost = [:]; reachable = nil; probedHosts = []
        if result.asr, let creds = AsrCreds.load() {
            voice.asr = VolcAsr(appid: creds.appid, token: creds.token, resourceId: creds.resourceId)
            NSLog("[VC] ASR creds imported → VolcAsr(resource=\(creds.resourceId))")
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
    func send(source: TerminalView, data: ArraySlice<UInt8>) { ssh?.send(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { ssh?.resize(cols: newCols, rows: newRows) }
    func scrolled(source: TerminalView, position: Double) {}
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
        if a != .voiceUp { keyHaptic.prepare(); keyHaptic.impactOccurred() }
        switch a {
        case .back:     backToList()
        case .up:       ssh?.send(Data(arrowBytes(0x41)))
        case .down:     ssh?.send(Data(arrowBytes(0x42)))
        case .right:    ssh?.send(Data(arrowBytes(0x43)))
        case .left:     ssh?.send(Data(arrowBytes(0x44)))
        case .enter:    if !voice.onEnter() { ssh?.send(Data([13])) }
        case .esc:      if !voice.onEsc()  { ssh?.send(Data([27])) }
        case .tab:      ssh?.send(Data([0x09]))
        case .shiftTab: ssh?.send(Data([0x1b, 0x5b, 0x5a]))
        case .ctrlC:    ssh?.send(Data([0x03]))
        case .ctrlB:    ssh?.send(Data([0x02]))
        case .delWord:  ssh?.send(Data([0x17]))
        case .voiceDown: voiceKeyAction(pressed: true)
        case .voiceUp:   voiceKeyAction(pressed: false)
        }
    }
    private func arrowBytes(_ final: UInt8) -> [UInt8] {
        let app = term.getTerminal().applicationCursor
        return [0x1b, app ? 0x4f : 0x5b, final]
    }

    // MARK: - 物理键 action(两条路由共用,幂等)
    private func voiceKeyAction(pressed: Bool) {
        guard view_ == .terminal else { return }
        if pressed {
            if !voiceKeyHeld { voiceKeyHeld = true; ensureMicThenRecord(); voice.voiceDown(lang: "zh") }
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
            asr = VolcAsr(appid: creds.appid, token: creds.token, resourceId: creds.resourceId)
            NSLog("[VC] ASR = VolcAsr(resource=\(creds.resourceId))")
        } else {
            asr = MockAsr()
            NSLog("[VC] ASR = MockAsr (no asr.json creds)")
        }
        voice = VoiceController(
            asr: asr,
            showOverlay: { [weak self] status, text in self?.voiceOverlay.show(status: status, text: text) },
            hideOverlay: { [weak self] in self?.voiceOverlay.hide() }
        )
        voice.inject = { [weak self] data in self?.ssh?.send(data) }
        voice.recorder = AudioCapture()   // 同步建好,否则首次 voiceDown recorder 还 nil
    }
    private func ensureMicThenRecord() {
        guard !micRequested else { return }
        micRequested = true
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            NSLog("[VC] mic permission = \(granted ? "granted" : "DENIED — 语音录不到音")")
        }
    }
    private func applyVoiceContext(_ project: ProjectConfig?) {
        if let project {
            voice.hotwords = Hotwords.merge(project.hotwords)
            voice.voiceMarkerEnabled = project.type.isAiAgent
        } else {
            voice.hotwords = Hotwords.base
            voice.voiceMarkerEnabled = false
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
        guard !didAutoOpen, view_ == .list else { return }
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
        for o in [kbConnectObs, kbDisconnectObs, foregroundObs, kbFrameObs, kbHideObs] {
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
