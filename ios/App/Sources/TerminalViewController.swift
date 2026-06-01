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
final class TerminalViewController: UIViewController, TerminalViewDelegate, TerminalHostKeyHandler {

    // 沉浸式全屏**只在终端态**(AR 眼镜):隐藏状态栏 + home indicator。列表态恢复标准 iOS chrome。
    override var prefersStatusBarHidden: Bool { view_ == .terminal }
    override var prefersHomeIndicatorAutoHidden: Bool { view_ == .terminal }

    // 原生列表(替代 WKWebView/index.html)。
    private let deckList = DeckListView(frame: .zero)
    // 原生终端(SwiftTerm):终端态渲染 + 键盘;列表态隐藏。
    private var term: TerminalHostView!
    // 语音预览浮层(原生)。
    private let voiceOverlay = VoiceOverlayView()
    // 触屏虚拟键盘(原生),无硬件键盘时挂为终端的 inputAccessoryView。
    private var keyBar: TerminalKeyBar!
    // 按键震动(VC 主窗口上下文触发;keybar 在键盘窗口里触发观测不到震动)。
    private let keyHaptic = UIImpactFeedbackGenerator(style: .light)
    // 键盘(触屏 vkey)避让:终端高度缩到键盘顶之上。
    private var keyboardOverlap: CGFloat = 0
    private var kbFrameObs: NSObjectProtocol?
    private var kbHideObs: NSObjectProtocol?

    private enum ViewState { case list, terminal }
    private var view_ = ViewState.list

    // Active PTY session (nil in list view).
    private var ssh: SSHSession?
    private var openSeq = 0      // fast open→back→open mustn't bind a stale PTY
    private var sessionGen = 0   // late output chunk from a closed session must not paint a new one

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
        navigationItem.title = "Deck"
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
        let t = TerminalHostView(frame: view.bounds, font: UIFont(name: "Menlo", size: 13))
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
        // tmux 触摸翻页(SPEC §6):点终端上半 = Shift+Up、下半 = Shift+Down。
        let pageTap = UITapGestureRecognizer(target: self, action: #selector(handleTermPageTap(_:)))
        pageTap.cancelsTouchesInView = false
        t.addGestureRecognizer(pageTap)

        // 触屏虚拟键盘:无硬件键盘时挂为终端 inputAccessoryView。
        let kb = TerminalKeyBar(width: view.bounds.width)
        kb.onAction = { [weak self] a in self?.handleKeyBarAction(a) }
        self.keyBar = kb
        updateTermAccessory()

        // 语音浮层最上层,默认隐藏。frame 由 layoutTerm 跟随 term(缩到 keybar 之上)。
        voiceOverlay.frame = view.bounds
        voiceOverlay.autoresizingMask = []
        view.addSubview(voiceOverlay)

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

        #if DEBUG
        applyDebugLevers()
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if view_ == .list { becomeFirstResponder() }   // 列表态 VC 收硬件键 → 列表导航
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
        let seq = { openSeq += 1; return openSeq }()
        view_ = .terminal
        showTerminalView()   // 显示 SwiftTerm + 抢焦 + 清屏 + 隐藏状态栏

        guard let h = hosts.first(where: { $0.name == host }),
              let p = (h.projects.first(where: { $0.session == session })) else {
            applyVoiceContext(nil)
            writeToTerm("\r\n[no SSH config for \(session)]\r\n")
            return
        }
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
                guard let self, self.sessionGen == gen, self.view_ == .terminal,
                      self.ssh === s else { return }   // only a live session that actually dropped
                NSLog("[VC] PTY dropped (server hangup / tmux kill) gen=\(gen)")
                self.ssh = nil
                self.writeToTerm("\r\n\u{1b}[33m[连接已断开 — 按返回键回到列表,重开此 project 可重连]\u{1b}[0m\r\n")
            }
        }
        s.connect(host: h, via: jump, session: p.session, cols: 80, rows: 24,
            onConnected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if seq != self.openSeq || self.view_ != .terminal {
                        NSLog("[VC] PTY connected but obsolete (seq=\(seq)) → close")
                        s.close(); return
                    }
                    self.ssh = s
                    NSLog("[VC] PTY live host=\(h.name) session=\(p.session)")
                    let t = self.term.getTerminal()
                    self.ssh?.resize(cols: t.cols, rows: t.rows)   // 补推当前终端尺寸(连接前 sizeChanged 时 ssh 还没绑定)
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
                    self.writeToTerm("\r\nSSH 连接失败: \(err)\r\n")
                }
            }
        )
    }

    private func backToList() {
        NSLog("[VC] backToList")
        voiceKeyHeld = false
        openSeq += 1
        sessionGen += 1
        voice.shutdown()
        applyVoiceContext(nil)
        view_ = .list
        let old = ssh
        ssh = nil
        old?.close()
        showListView()
        refreshManifests()   // a project Maestro just created shows up now
    }

    // MARK: - 终端/列表 view 切换
    private func showTerminalView() {
        term.feed(text: "\u{1b}c")      // RIS 全复位
        term.isHidden = false
        view.bringSubviewToFront(term)
        view.bringSubviewToFront(voiceOverlay)
        updateTermAccessory()
        term.becomeFirstResponder()
        navigationController?.setNavigationBarHidden(true, animated: true)   // 终端沉浸:隐藏 nav bar
        setNeedsStatusBarAppearanceUpdate()                                  // + 状态栏 + home indicator
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    private func showListView() {
        voiceOverlay.hide()
        term.resignFirstResponder()
        term.isHidden = true
        becomeFirstResponder()          // 列表态 VC 收硬件键 → 列表导航
        pushList()
        navigationController?.setNavigationBarHidden(false, animated: true)  // 列表:恢复 nav bar(大标题)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    // MARK: - 键盘(触屏 vkey)避让
    private func registerKeyboardAvoidance() {
        let nc = NotificationCenter.default
        kbFrameObs = nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let v = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let kbInView = self.view.convert(v, from: nil)
            self.keyboardOverlap = max(0, self.view.bounds.maxY - kbInView.minY)
            self.layoutTerm()
        }
        kbHideObs = nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keyboardOverlap = 0; self?.layoutTerm()
        }
    }
    private func layoutTerm() {
        guard let term else { return }
        let f = CGRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - keyboardOverlap))
        term.frame = f
        voiceOverlay.frame = f
    }

    /// tmux 触摸翻页:终端上半 → Shift+Up(`ESC[1;2A`);下半 → Shift+Down(`ESC[1;2B`)。
    @objc private func handleTermPageTap(_ g: UITapGestureRecognizer) {
        guard view_ == .terminal else { return }
        keyHaptic.prepare(); keyHaptic.impactOccurred()
        let topHalf = g.location(in: term).y < term.bounds.height / 2
        ssh?.send(Data(topHalf ? [0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41] : [0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x42]))
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
        // 若导入时终端正活着,先拆掉(背景→Open in→前台在终端)。
        if view_ == .terminal {
            openSeq += 1; sessionGen += 1
            voice.shutdown(); applyVoiceContext(nil)
            let old = ssh; ssh = nil; old?.close()
        }
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
        }
        kbDisconnectObs = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            NSLog("[VC] GCKeyboard disconnected")
            self?.voiceKeyHeld = false
            self?.updateTermAccessory()   // 终端:挂回触屏 vkey
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
        term.inputAccessoryView = (GCKeyboard.coalesced == nil) ? keyBar : nil
        if view_ == .terminal, term.isFirstResponder { term.reloadInputViews() }
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
