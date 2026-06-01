import UIKit
import WebKit
import GameController
import AVFoundation
import SwiftTerm

/// Core-loop controller. Mirrors Android's MainActivity:
///   hosts.json → Agent Deck list → openProject → SSH(ed25519) PTY terminal → back.
///
/// **架构(2026-06 改)**:列表态 = WKWebView 跑共享 `index.html`(Agent Deck SPA);终端态 = **原生
/// SwiftTerm `TerminalView`**(替代 WKWebView 里的 xterm.js)。原因:iOS WKWebView 收不到硬件键 DOM
/// 事件 + 软键盘抑制与 DOM 投递互斥 → 键盘死结。SwiftTerm 是原生 VT100 引擎,键盘全原生正确处理。
/// 两个 view 叠放,按 view_ 显隐切换;F1/F2 + 语音 overlay 原生。
final class TerminalViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate,
                                     TerminalViewDelegate, TerminalHostKeyHandler {

    // 全屏沉浸(AR 眼镜场景):隐藏状态栏(时间/电量/信号)+ home indicator = Android immersive。
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private var webView: WKWebView!
    private var pageReady = false

    // 原生终端(SwiftTerm):终端态渲染 + 键盘;列表态隐藏。替代 WKWebView 里的 xterm。
    private var term: TerminalHostView!
    // 语音预览浮层(原生),替代 index.html 的 showOverlay/hideOverlay。
    private let voiceOverlay = VoiceOverlayView()
    // 触屏虚拟键盘(原生),无硬件键盘时挂为终端的 inputAccessoryView。
    private var keyBar: TerminalKeyBar!

    private enum ViewState { case list, terminal }
    private var view_ = ViewState.list

    // Active PTY session (nil in list view). Mirrors Android's activeChannel swap.
    private var ssh: SSHSession?
    // open序号 race guard (Android openSeq): fast open→back→open mustn't bind a stale PTY.
    private var openSeq = 0
    // reader/session generation: a late output chunk from a closed session must not
    // paint over a new one. Bumped on every switch.
    private var sessionGen = 0

    private var hosts: [HostConfig] = []
    // Live status from the last manifest+status fetch (SPEC §3). nil reachable = not yet
    // probed → list pushes omit `state` so the JS shows seed/loading instead of a badge.
    private var statusByHost: [String: [String: SessionState]] = [:]
    private var reachable: Set<String>? = nil
    // Phase 3 incremental loading: hosts whose probe has landed this round. A host NOT in
    // here is still loading (spinner); replaces the all-or-nothing `loading` flag so a live
    // host can show real status while a dead host still spins toward its timeout.
    private var probedHosts: Set<String> = []
    // Phase 3 race guard (Android's fetchGen): foreground + back-to-list can both fire
    // refreshManifests → overlapping fetch Tasks. Each fetch captures the current gen;
    // stale results (and stale per-host callbacks) are dropped on the main hop.
    private var fetchGen = 0
    // GameController keyboard observers (hardware keyboard → hide vkey, SPEC §6.1).
    private var kbConnectObs: NSObjectProtocol?
    private var kbDisconnectObs: NSObjectProtocol?
    // Phase 3: app-foreground observer → refetch status when the user returns (Android onStart).
    private var foregroundObs: NSObjectProtocol?

    // 语音输入(Android VoiceDaemon 的对应):状态机 + ASR + 注入。index.html 的语音键经
    // Bridge.voiceDown/voiceUp 进来 → voice.voiceDown/voiceUp;overlay 走注入的 window.showOverlay。
    // 实例创建后不重建(inject 闭包按 open 热切,等价 Android @Volatile channel)。
    private var voice: VoiceController!
    private var micRequested = false
    // 物理键 F1(语音 hold-to-talk)按住态:GameController 的 keyChangedHandler 在状态变化时各发一次
    // (理论上不像 Android ACTION_DOWN 会自动重复),仍加此 guard 防重复 voiceDown / 漏 up。
    private var voiceKeyHeld = false

    // MARK: - Bridge shim (injected at document start)
    // index.html calls window.Bridge.{onInput,onResize,openProject,goHome,vkeyEnter,...};
    // each forwards to the bridge message handler. Every method the SPA *might* call is
    // defined so its `if(window.Bridge && window.Bridge.x)` guards pass.
    private let bridgeShim = """
    window.Bridge = {
      onInput:    function(b64){ window.webkit.messageHandlers.bridge.postMessage({m:'onInput',    a:[b64]}); },
      onResize:   function(c,r){ window.webkit.messageHandlers.bridge.postMessage({m:'onResize',   a:[c,r]}); },
      openProject:function(h,s,n,t){ window.webkit.messageHandlers.bridge.postMessage({m:'openProject', a:[h,s,n,t]}); },
      goHome:     function(){ window.webkit.messageHandlers.bridge.postMessage({m:'goHome', a:[]}); },
      vkeyEnter:  function(){ window.webkit.messageHandlers.bridge.postMessage({m:'vkeyEnter', a:[]}); },
      vkeyEsc:    function(){ window.webkit.messageHandlers.bridge.postMessage({m:'vkeyEsc', a:[]}); },
      voiceDown:  function(l){ window.webkit.messageHandlers.bridge.postMessage({m:'voiceDown', a:[l]}); },
      voiceUp:    function(l){ window.webkit.messageHandlers.bridge.postMessage({m:'voiceUp', a:[l]}); },
      hasHardwareKeyboard: function(){ return false; }
    };
    """

    private let consoleShim = """
    (function(){
      function send(level, args){
        try {
          var s = Array.prototype.map.call(args, function(a){
            try { return (typeof a==='object') ? JSON.stringify(a) : String(a); }
            catch(e){ return String(a); }
          }).join(' ');
          window.webkit.messageHandlers.log.postMessage({level:level, text:s});
        } catch(e){}
      }
      ['log','warn','error','info'].forEach(function(k){
        var orig = console[k];
        console[k] = function(){ send(k, arguments); orig && orig.apply(console, arguments); };
      });
      window.addEventListener('error', function(e){
        send('uncaught', [(e.message||'')+' @ '+(e.filename||'')+':'+(e.lineno||'')]);
      });
      window.addEventListener('unhandledrejection', function(e){
        send('reject', [String(e.reason)]);
      });
    })();
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: consoleShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "bridge")
        ucc.add(self, name: "log")
        cfg.userContentController = ucc
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        view.addSubview(webView)

        // 原生终端(SwiftTerm),覆盖在 webView 之上,默认隐藏,终端态显示。
        TerminalKeyInterceptor.installOnce()   // swizzle pressesBegan 拦 F1/F2 + 语音 Enter/Esc
        let t = TerminalHostView(frame: view.bounds, font: UIFont(name: "Menlo", size: 13))
        t.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        t.terminalDelegate = self
        t.keyHandler = self
        t.nativeBackgroundColor = .black
        t.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        // AR 眼镜:纯硬件键盘,不弹软键盘也不要 SwiftTerm 自带的触屏终端工具条。
        // inputView 设 0 高度空 view = iOS 用它代替系统键盘(看不见),但仍是键盘 first responder → 硬件键照常进。
        // inputAccessoryView 由 updateTermAccessory 按是否有硬件键盘挂触屏 vkey / 设 nil。
        t.inputView = UIView(frame: .zero)
        t.isHidden = true
        view.addSubview(t)
        self.term = t

        // 触屏虚拟键盘:无硬件键盘时挂为 inputAccessoryView(文本靠语音,只放特殊键)。
        let kb = TerminalKeyBar(width: view.bounds.width)
        kb.onAction = { [weak self] a in self?.handleKeyBarAction(a) }
        self.keyBar = kb
        updateTermAccessory()

        // 语音浮层最上层,默认隐藏。
        voiceOverlay.frame = view.bounds
        voiceOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(voiceOverlay)

        setupVoice()

        hosts = HostStore.loadHosts()
        NSLog("[VC] loaded \(hosts.count) hosts from hosts.json")

        guard let webDir = Bundle.main.url(forResource: "web", withExtension: nil) else {
            NSLog("[VC] FATAL: web/ folder not found in bundle"); return
        }
        let indexURL = webDir.appendingPathComponent("index.html")
        webView.loadFileURL(indexURL, allowingReadAccessTo: webDir)

        registerKeyboardObservers()
        registerForegroundObserver()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if view_ == .list { becomeFirstResponder() }   // 列表态 VC 收硬件键 → 列表导航(navKey)
    }

    // MARK: - App foreground → refetch status (item 1; Android's onStart guarded by LIST)
    /// AppDelegate-based app with a manual UIWindow + no SceneDelegate, so we use
    /// `willEnterForegroundNotification` (fires reliably on warm foreground; the UIScene
    /// variant needs scene adoption we don't have). Refetch only in the LIST view — refetching
    /// while in a terminal would pointlessly SSH every host; the terminal's own PTY is what
    /// matters there. Matches Android MainActivity.onStart (`if view == LIST refreshManifests`).
    private func registerForegroundObserver() {
        foregroundObs = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            NSLog("[VC] willEnterForeground view=\(self.view_ == .list ? "list" : "terminal")")
            if self.view_ == .list, !self.hosts.isEmpty { self.refreshManifests() }
        }
    }

    // 配置导入(SPEC §8):本版**只走分享单「Open in」**(Valet AirDrop 自含 `.xrhosts`,
    // AppDelegate.application(_:open:) 处理 → importConfig → reloadHostsAfterImport)。
    // app 内「齿轮→host 配置页文档选择器」那套手动导入**搁置 P2**(与「无设置 UI / agent 代劳」
    // 哲学略拧;AirDrop 已够)。importConfig 的三类判别(单 host/全局/asr)对 AirDrop 文件仍生效。

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[VC] index.html loaded")
        pageReady = true
        // Push seed list immediately (Enter can open a real terminal), then refresh
        // from manifest. If no hosts configured, leave the index.html mock in place.
        if !hosts.isEmpty {
            pushHostList(loading: true)   // seed list with spinners; real status fills in after fetch
            refreshManifests()
        }
        pushHwKeyboardState()
        #if DEBUG
        applyDebugLevers()
        #endif
    }

    #if DEBUG
    /// Screenshot-only levers (launch-arg gated, no production effect):
    /// `-forceShowVkey` forces the virtual keyboard visible (the sim always reports a
    /// hardware keyboard, which would hide it); `-forceLandscape` rotates to a real
    /// landscape viewport so the `@media (orientation)` CSS actually flips.
    private func applyDebugLevers() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-forceShowVkey") {
            eval("window.setHwKeyboard && window.setHwKeyboard(false)")
        }
        if args.contains("-forceLandscape") {
            requestOrientation(.landscapeRight)
        }
        // Voice self-verify (no mic / no creds needed): drive the REAL bridge → VoiceController →
        // overlay chain with MockAsr. Fires Bridge.voiceDown('zh') then voiceUp after a beat, walking
        // 聆听中… → "ls -la" → 已识别 (PREVIEW) so a screenshot proves the injected overlay + state
        // machine. Production launches pass no such arg → no effect.
        if args.contains("-voiceMicTest") {
            // Exercise the REAL recording path (AudioCapture via AVAudioEngine on the Mac mic): open a
            // project, attach the recorder (mic pre-granted via simctl), then voiceDown to start the tap.
            // Confirms tap fires + 16k/mono/Int16 conversion (look for [AudioCapture] tap# / started: logs).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onOpenProject(host: "demo", session: "demo", name: "mic-test", type: "claude")
                self?.voice.recorder = AudioCapture()   // mic pre-granted → attach directly
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.voice.voiceDown(lang: "zh")   // starts AudioCapture.start → tap → ASR send
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self?.voice.voiceUp(lang: "zh")
                    }
                }
            }
        }
        if args.contains("-voiceDemo") {
            // Drive the voice chain in the REALISTIC view (terminal, where voice runs): open a mock
            // project first (the [no SSH config] branch still flips to #view-term), then voiceDown/Up.
            // Skip ensureMicThenRecord so no permission modal blocks the screenshot; MockAsr ignores
            // audio. Walks 聆听中… → "ls -la" → 已识别 PREVIEW so the overlay + state machine show.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onOpenProject(host: "demo", session: "demo", name: "voice-demo", type: "claude")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.voice.voiceDown(lang: "zh")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.voice.voiceUp(lang: "zh")   // → MockAsr final → 已识别 PREVIEW
                    }
                }
            }
        }
        // Verify the "Open in" import path without an AirDrop: -importConfigPath <file> runs the
        // exact same HostStore.importConfig + reloadHostsAfterImport an open: would (the sim can
        // read /tmp at the BSD level). Production launches pass no such arg → no effect.
        if let i = args.firstIndex(of: "-importConfigPath"), i + 1 < args.count {
            let path = args[i + 1]
            NSLog("[VC] DEBUG -importConfigPath \(path)")
            do {
                let r = try HostStore.importConfig(from: URL(fileURLWithPath: path))
                reloadHostsAfterImport(r)
            } catch {
                reportImportFailure("\(error)")
            }
        }
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = view.window?.windowScene else { return }
        let geo = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(geo) { err in NSLog("[VC] orientation update: \(err)") }
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    #endif

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[VC] navigation FAILED: \(error)")
    }

    /// WKWebView analog of Android's onRenderProcessGone→recreate (graceful degradation,
    /// SPEC §9): the WebGL render content-process was killed (OOM / GPU context loss). Default
    /// behavior leaves a blank webview; instead reload index.html so the app self-heals back
    /// to the list. Any live PTY is torn down (its render target is gone) and the user lands
    /// on a fresh list. NOTE: not reproducible in the simulator — implemented defensively + logged.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[VC] WebContent process TERMINATED → reload index.html (self-heal to list)")
        pageReady = false
        ssh?.close(); ssh = nil
        sessionGen += 1; openSeq += 1
        view_ = .list
        term?.isHidden = true; term?.resignFirstResponder(); voiceOverlay.hide()
        guard let webDir = Bundle.main.url(forResource: "web", withExtension: nil) else { return }
        webView.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)
        // didFinish will re-seed the list + refreshManifests as on a fresh load.
    }

    // MARK: - List push + manifest refresh
    /// Push the current deck to the list view, merging the last-known live status.
    /// `loading:true` (the very first pre-fetch push) spins every card and omits state.
    /// After that, per-host loading is driven by `probedHosts`: a host not yet probed keeps
    /// spinning while already-resolved hosts show real badges (Phase 3 incremental).
    private func pushHostList(loading: Bool = false) {
        let json = DeckJSON.hostsArray(
            hosts, loading: loading,
            statusByHost: statusByHost,
            reachable: loading ? nil : reachable,   // loading push = unprobed → no state yet
            probed: loading ? nil : probedHosts     // nil = treat all as loading (initial seed)
        )
        eval("window.setHosts(\(jsString(json)))")
    }

    /// Fetch each host's manifest + status off the main actor (concurrent + per-host timeout
    /// in ManifestFetcher), re-pushing the list INCREMENTALLY as each host resolves so a live
    /// host appears immediately and a dead host only flips to disconnected at its timeout —
    /// it never hangs the list (SPEC §9). Runs on initial list entry, back-to-list, and
    /// app-foreground. `fetchGen` discards results from a superseded fetch.
    private func refreshManifests() {
        let snapshot = hosts
        fetchGen += 1
        let gen = fetchGen
        // SPEC §3 anti-flicker: do NOT clear probedHosts on a warm refresh (foreground /
        // back-to-list). The cold path already shows spinners via didFinish's loading push;
        // once the first fetch fills probedHosts, later refreshes keep every host's last-known
        // badge and update it IN PLACE as it re-resolves — a settled `offline` host must not
        // revert to a 7s spinner just because the user returned. Only the cold load (empty
        // set, never yet probed) spins. Mirrors Android holding the old list across a refetch.
        Task {
            let result = await ManifestFetcher.fetch(snapshot) { [weak self] r in
                // Per-host landing (already on MainActor). Merge just this host's outcome and
                // re-push so the live ones show up without waiting for the dead one.
                guard let self, gen == self.fetchGen else { return }
                self.probedHosts.insert(r.host.name)
                self.statusByHost[r.host.name] = r.status
                if r.liveFetched {
                    var reach = self.reachable ?? []
                    if r.reachable { reach.insert(r.host.name) } else { reach.remove(r.host.name) }
                    self.reachable = reach
                }
                self.hosts = self.hosts.map { $0.name == r.host.name ? r.host : $0 }
                if self.view_ == .list { self.pushHostList(loading: false) }
            }
            await MainActor.run {
                guard gen == self.fetchGen else { return }   // a newer fetch already owns the UI
                self.hosts = result.hosts
                self.statusByHost = result.statusByHost
                self.reachable = result.reachable
                // Every host in this round has now resolved → no more spinners.
                self.probedHosts = Set(result.hosts.map { $0.name })
                if self.view_ == .list { self.pushHostList(loading: false) }
                #if DEBUG
                self.maybeAutoOpen()   // self-verification hook (launch-arg gated)
                #endif
            }
        }
    }

    #if DEBUG
    /// Self-verification only: with `-autoOpenSession <name>` (and optional `-autoOpenHost`)
    /// in the scheme/launch args, auto-open that project once the real manifest is in.
    /// `-autoCycleSession <name2>` additionally drives open→back→reopen to verify the
    /// teardown / openSeq / sessionGen race guards (must rebind correctly, not hang).
    /// Production launches pass no such arg → no effect.
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

        if let j = args.firstIndex(of: "-autoCycleSession"), j + 1 < args.count,
           let p2 = h.projects.first(where: { $0.session == args[j + 1] }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.backToList()   // verify teardown does not hang
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.onOpenProject(host: host, session: p2.session, name: p2.name, type: p2.type.rawValue)
                }
            }
        }
    }
    #endif

    // MARK: - WKScriptMessageHandler
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "log" {
            if let d = message.body as? [String: Any] {
                NSLog("[JS:\(d["level"] ?? "?")] \(d["text"] ?? "")")
            }
            return
        }
        guard message.name == "bridge", let body = message.body as? [String: Any],
              let m = body["m"] as? String else { return }
        let a = body["a"] as? [Any] ?? []
        switch m {
        case "onInput":
            if let b64 = a.first as? String, let data = Data(base64Encoded: b64) { ssh?.send(data) }
        case "onResize":
            let cols = (a.first as? NSNumber)?.intValue ?? 0
            let rows = (a.count > 1 ? a[1] as? NSNumber : nil)?.intValue ?? 0
            if cols > 0, rows > 0 { ssh?.resize(cols: cols, rows: rows) }
        case "openProject":
            let host = a.indices.contains(0) ? (a[0] as? String ?? "") : ""
            let session = a.indices.contains(1) ? (a[1] as? String ?? "") : ""
            let name = a.indices.contains(2) ? (a[2] as? String ?? "") : ""
            let type = a.indices.contains(3) ? (a[3] as? String ?? "") : ""
            onOpenProject(host: host, session: session, name: name, type: type)
        case "goHome":
            if view_ == .terminal { backToList() }
        case "vkeyEnter":
            // PREVIEW: first Enter injects the recognized text (no CR —误识安全网, SPEC §4);
            // otherwise normal CR. Mirrors Android onVkeyEnter = if(!voice.onEnter()) writeChannelByte(13).
            if !voice.onEnter() { ssh?.send(Data([13])) }   // CR
        case "vkeyEsc":
            if !voice.onEsc() { ssh?.send(Data([27])) }     // ESC (cancels a voice session if active)
        case "voiceDown":
            let lang = (a.first as? String) ?? "zh"
            ensureMicThenRecord()
            voice.voiceDown(lang: lang)
        case "voiceUp":
            let lang = (a.first as? String) ?? "zh"
            voice.voiceUp(lang: lang)
        default:
            NSLog("[VC] bridge msg \(m) \(a)")
        }
    }

    // MARK: - Open project → PTY
    private func onOpenProject(host: String, session: String, name: String, type: String) {
        NSLog("[VC] openProject host=\(host) session=\(session)")
        let seq = { openSeq += 1; return openSeq }()
        view_ = .terminal
        showTerminalView()   // 显示 SwiftTerm + 抢焦 + 清屏

        guard let h = hosts.first(where: { $0.name == host }),
              let p = (h.projects.first(where: { $0.session == session })) else {
            // mock / unconfigured — nothing to connect to; stay on the (empty) terminal.
            applyVoiceContext(nil)   // no project context → BASE words, marker off
            writeToTerm("\r\n[no SSH config for \(session)]\r\n")
            return
        }
        // Voice context for this project: BASE + its hotwords, 🎤 marker on for AI-agent types.
        applyVoiceContext(p)
        // Multi-hop (SPEC §5): if this host has a `via`, resolve the jump host by name from
        // the deck (mirrors Android's byName lookup) so the PTY tunnels through it. Unknown
        // via name → nil → direct (degrade, don't fail the open).
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
        // PTY loop ended (item 3). onClosed fires for user-back, a server-side drop
        // (tmux kill-session, connection drop), AND a connect failure (connect() always calls
        // onClosed after its do/catch). backToList already bumped sessionGen, so its close
        // no-ops here. The `self.ssh === s` guard distinguishes a *live* session that dropped
        // (ssh was assigned in onConnected) from a connect failure that never went live (ssh
        // still nil → onFailure already showed "连接失败", don't also print "连接已断开").
        // We do NOT auto-navigate: the user keeps their terminal context and chooses to leave
        // (graceful, SPEC §9 — never freeze, never crash). Reopen rebuilds via `tmux new -A`.
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
                    // open→back→open race: user already left → discard this connection.
                    if seq != self.openSeq || self.view_ != .terminal {
                        NSLog("[VC] PTY connected but obsolete (seq=\(seq)) → close")
                        s.close(); return
                    }
                    self.ssh = s
                    NSLog("[VC] PTY live host=\(h.name) session=\(p.session)")
                    // 连接前 sizeChanged 可能已触发(那时 ssh 还没绑定)→ 这里把当前终端尺寸补推给 PTY,
                    // 否则 PTY 停在 connect 时传的 80×24、tmux 画不满。
                    let t = self.term.getTerminal()
                    self.ssh?.resize(cols: t.cols, rows: t.rows)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-autoTypeAfterOpen") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.ssh?.send(Data("echo XREAL_OK\n".utf8))
                        }
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
        voiceKeyHeld = false   // 若按住 F1 时按 F2 离开,清掉按住态,否则下次 F1 不触发
        openSeq += 1     // in-flight connections are now obsolete
        sessionGen += 1  // late output chunks are now obsolete
        voice.shutdown() // cancel any in-flight voice session + hide overlay before leaving
        applyVoiceContext(nil)
        view_ = .list
        let old = ssh
        ssh = nil
        old?.close()     // finishes stream + closes client → PTY loop exits, tmux persists
        showListView()
        refreshManifests()   // a project Maestro just created shows up now
    }

    // MARK: - 终端/列表 view 切换(SwiftTerm 显隐 + first responder 归属)
    /// 进终端态:清屏 + 显示 SwiftTerm + 它抢 first responder(硬件键进它,由它编码)。
    private func showTerminalView() {
        term.feed(text: "\u{1b}c")      // RIS 全复位,清掉上次 session 残留
        term.isHidden = false
        view.bringSubviewToFront(term)
        view.bringSubviewToFront(voiceOverlay)
        updateTermAccessory()           // 按当前是否有硬件键盘挂/卸触屏 vkey
        term.becomeFirstResponder()
    }

    /// 无硬件键盘 → 挂触屏 vkey 为 inputAccessoryView;有硬件键盘 → nil(纯硬件键)。
    /// term 在 becomeFirstResponder 时读 inputAccessoryView;运行中变更(插拔键盘)需 reloadInputViews。
    private func updateTermAccessory() {
        guard let term, let keyBar else { return }
        term.inputAccessoryView = (GCKeyboard.coalesced == nil) ? keyBar : nil
        if view_ == .terminal, term.isFirstResponder { term.reloadInputViews() }
    }

    /// 触屏 vkey 动作 → 字节发 ssh / app 动作。Enter/Esc voice-aware;方向键 DECCKM 适配。
    private func handleKeyBarAction(_ a: TerminalKeyAction) {
        switch a {
        case .back:     backToList()
        case .up:       ssh?.send(Data(arrowBytes(0x41)))
        case .down:     ssh?.send(Data(arrowBytes(0x42)))
        case .right:    ssh?.send(Data(arrowBytes(0x43)))
        case .left:     ssh?.send(Data(arrowBytes(0x44)))
        case .enter:    if !voice.onEnter() { ssh?.send(Data([13])) }    // 预览态注入;否则 CR
        case .esc:      if !voice.onEsc()  { ssh?.send(Data([27])) }     // 取消会话;否则 ESC
        case .tab:      ssh?.send(Data([0x09]))
        case .shiftTab: ssh?.send(Data([0x1b, 0x5b, 0x5a]))             // ESC [ Z(back-tab)
        case .ctrlC:    ssh?.send(Data([0x03]))
        case .delWord:  ssh?.send(Data([0x17]))                         // Ctrl-W 删词
        case .voiceDown: ensureMicThenRecord(); voice.voiceDown(lang: "zh")
        case .voiceUp:   voice.voiceUp(lang: "zh")
        }
    }

    /// 方向键字节,DECCKM 适配:application cursor 模式发 `ESC O X`,否则 `ESC [ X`。
    private func arrowBytes(_ final: UInt8) -> [UInt8] {
        let app = term.getTerminal().applicationCursor
        return [0x1b, app ? 0x4f : 0x5b, final]
    }
    /// 回列表态:隐藏 SwiftTerm + 让 VC 收硬件键(列表导航走 handlePresses → navKey)。
    private func showListView() {
        voiceOverlay.hide()
        term.resignFirstResponder()
        term.isHidden = true
        becomeFirstResponder()          // 列表态 VC 当 first responder → 方向键/Enter 进 handlePresses
        eval("window.showList()")
    }

    // MARK: - Valet "Open in" import → reload list (SPEC §8 real-device channel)
    /// Called by AppDelegate after a `.xrhosts` file imports into private storage. Re-read the
    /// now-updated hosts.json from disk (refreshManifests only walks the in-memory snapshot, so it
    /// would never discover a freshly-imported host) and re-seed the list, then live-fetch.
    /// Order-robust on cold-launch-via-file: if the page isn't ready yet, didFinish's own
    /// `if !hosts.isEmpty` push covers it (we've set self.hosts); if ready, we push now.
    /// Takes the full ImportResult so the toast reflects what actually landed — an asr-only
    /// import has 0 hosts, so a bare "N host" line would read "0 host" (wrong, and on the
    /// AirDrop path there's no native alert to correct it).
    func reloadHostsAfterImport(_ result: HostStore.ImportResult) {
        NSLog("[VC] reloadHostsAfterImport: mode=\(result.mode) hosts=\(result.hosts) asr=\(result.asr)")
        hosts = HostStore.loadHosts()
        statusByHost = [:]; reachable = nil; probedHosts = []
        // An asr-bearing import just delivered real creds → swap MockAsr → VolcAsr now (the next
        // voice press uses live ASR without a relaunch). Mirrors Android re-reading loadAsr.
        if result.asr, let creds = AsrCreds.load() {
            voice.asr = VolcAsr(appid: creds.appid, token: creds.token, resourceId: creds.resourceId)
            NSLog("[VC] ASR creds imported → VolcAsr(resource=\(creds.resourceId))")
        }
        guard pageReady else { return }   // didFinish will seed+refresh once loaded
        // If a file is opened while a PTY is live (background → "Open in" → foreground in terminal),
        // tear the session down before switching to the list — otherwise onOutput keeps painting a
        // hidden xterm and the tmux attach leaks (bump openSeq/sessionGen so late chunks no-op).
        if view_ == .terminal {
            openSeq += 1; sessionGen += 1
            voice.shutdown(); applyVoiceContext(nil)   // cancel in-flight voice + hide overlay
            let old = ssh; ssh = nil; old?.close()
        }
        if view_ != .list { view_ = .list; showListView() }
        toast(importToast(result))
        pushHostList(loading: true)
        refreshManifests()
    }

    /// One-liner in-WebView toast for an import. Mode-aware so asr-only doesn't read "0 host".
    private func importToast(_ r: HostStore.ImportResult) -> String {
        switch r.mode {
        case .asrOnly: return "ASR 凭证已导入"
        case .append:  return "导入成功:追加 \(r.hosts) host" + (r.asr ? " + ASR" : "")
        case .replace: return "导入成功:\(r.hosts) host" + (r.asr ? " + ASR" : "")
        }
    }

    /// Surface an import parse/validation failure (bad JSON, no valid host) without crashing —
    /// graceful degradation (SPEC §9): the user keeps whatever list they already had.
    func reportImportFailure(_ message: String) {
        NSLog("[VC] import failure: \(message)")
        if pageReady { toast("导入失败:\(message)") }
    }

    /// Lightweight in-WebView toast (no native alert chrome over the AR-glasses UI). Uses the
    /// shared index.html if it exposes window.toast; otherwise a no-op (the list refresh is the
    /// real feedback). Kept defensive so an absent JS hook never throws.
    private func toast(_ s: String) {
        eval("window.toast && window.toast(\(jsString(s)))")
    }

    // MARK: - Hardware keyboard detection (SPEC §6.1)
    private func registerKeyboardObservers() {
        kbConnectObs = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            NSLog("[VC] GCKeyboard connected → hide vkey")
            self?.eval("window.setHwKeyboard && window.setHwKeyboard(true)")   // 列表 webView vkey
            self?.attachKeyHandler()      // 接 F1/F2 物理键路由
            self?.updateTermAccessory()   // 终端:卸掉触屏 vkey
        }
        kbDisconnectObs = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            NSLog("[VC] GCKeyboard disconnected → show vkey")
            self?.eval("window.setHwKeyboard && window.setHwKeyboard(false)")
            self?.voiceKeyHeld = false    // 键盘拔了,清掉可能卡住的按住态
            self?.updateTermAccessory()   // 终端:挂回触屏 vkey
        }
        attachKeyHandler()   // 键盘可能在 viewDidLoad 前就已连上(connect 通知已错过)→ 直接挂到 coalesced
    }

    // MARK: - 物理键路由(8BitDo / 蓝牙键盘)
    /// SPEC §6/§11 语义:F1 = 语音 hold-to-talk、F2 = 返回列表、方向键导航、Enter 确认/执行、Esc 取消。
    /// **核心事实(真机实测)**:iOS 上硬件键盘**完全不进 WKWebView DOM** —— 终端态 `term.focus()` 也没用,
    /// 每个键(含字符/Enter/Esc/方向)都经 UIKit 响应链冒泡到 VC 的 `pressesBegan`,xterm.onData / DOM keydown
    /// 对硬件键永不触发(疑因 AR 眼镜的 IME 抑制 swizzle,根因不影响修复)。**故整条键盘输入都在原生处理**:
    ///   - 列表态:方向键/Enter → `window.navKey`(SPA 导航);
    ///   - 终端态:键 → 字节发 ssh(`terminalKey`,对齐 Android `dispatchKeyEvent`,Enter/Esc voice-aware)。
    /// 8BitDo 在 iOS 实测发标准 HID:语音键=F1(58)、返回键=F2(59),与 Android 一致(经 Generic.kl)。
    /// GameController(`keyChangedHandler`)在有 WKWebView 抢焦时**收不到** key 回调 → 仅作冗余兜底,主路由是
    /// `pressesBegan`;GameController 的 connect/disconnect 仍负责**检测键盘插拔**显隐 vkey(一直正常)。
    /// 终端态 `terminalKey` 做**完整键盘翻译**(可打印字符 + 控制键 + Ctrl 组合)→ 接全 BT 键盘自由打字。
    /// (曾有每键 keyCode 发现日志,映射定了已删 —— 终端打字含密码,不该 keylog 进 syslog。)
    private func attachKeyHandler() {
        guard let kb = GCKeyboard.coalesced else { return }
        kb.handlerQueue = .main   // handler 内要碰 UIKit/voice/webView → 必须主线程
        kb.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            if keyCode == .F1 { self?.voiceKeyAction(pressed: pressed) }
            else if keyCode == .F2 { self?.backKeyAction(pressed: pressed) }
        }
        NSLog("[VC] GCKeyboard key handler attached")
    }

    // MARK: - UIPress(主路由):硬件键在响应链冒泡到 VC
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handlePresses(presses, pressed: true) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handlePresses(presses, pressed: false) { return }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        _ = handlePresses(presses, pressed: false)   // cancel 当松手处理(别让语音卡在录音)
        super.pressesCancelled(presses, with: event)
    }

    // 列表态 VC 当 first responder 收硬件键(方向键/Enter → 列表导航)。终端态由 SwiftTerm(TerminalHostView)收键。
    override var canBecomeFirstResponder: Bool { true }

    /// 硬件键 → 处理。**仅列表态**:方向键/Enter 驱动 SPA 列表导航;F1/F2 转 action(列表态 no-op)。
    /// 终端态键盘由 SwiftTerm 直接处理(全键盘正确编码),**不经这里**。@return true 若 consume。
    private func handlePresses(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var handled = false
        for p in presses {
            guard let key = p.key else { continue }
            switch key.keyCode {
            case .keyboardF1: voiceKeyAction(pressed: pressed); handled = true
            case .keyboardF2: backKeyAction(pressed: pressed); handled = true
            default:
                guard pressed, view_ == .list, let nav = Self.listNavKey(key.keyCode) else { break }
                eval("window.navKey && window.navKey('\(nav)')"); handled = true
            }
        }
        return handled
    }

    /// 硬件方向键 / Enter → SPA 列表导航方向串(仅列表视图用)。
    private static func listNavKey(_ code: UIKeyboardHIDUsage) -> String? {
        switch code {
        case .keyboardDownArrow:  return "down"
        case .keyboardUpArrow:    return "up"
        case .keyboardRightArrow: return "right"
        case .keyboardLeftArrow:  return "left"
        case .keyboardReturnOrEnter, .keypadEnter: return "enter"
        default: return nil
        }
    }

    // MARK: - SwiftTerm delegate(终端 → app):用户输入发 ssh、尺寸变化重设 PTY
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
    func termVoiceKey(down: Bool) { voiceKeyAction(pressed: down) }   // F1 hold-to-talk
    func termBackKey() { backToList() }                              // F2 → 列表
    func termVoiceActive() -> Bool { voice.currentState != .idle }   // overlay 可见 → 抢 Enter/Esc
    func termVoiceEnter() -> Bool { voice.onEnter() }                // 预览态注入(true=接管);否则透传 CR
    func termVoiceEsc() -> Bool { voice.onEsc() }                    // 取消会话(true=接管);否则透传 ESC

    // MARK: - 物理键 action(两条路由共用,幂等)
    /// F1 = 语音 hold-to-talk。按住时 pressesBegan 可能因 key-repeat 重复 → voiceKeyHeld 去重;松开/取消才结束。
    private func voiceKeyAction(pressed: Bool) {
        guard view_ == .terminal else { return }   // 列表页不介入(列表页 F2→host 配置页随配置页搁 P2)
        if pressed {
            if !voiceKeyHeld { voiceKeyHeld = true; ensureMicThenRecord(); voice.voiceDown(lang: "zh") }
        } else if voiceKeyHeld {
            voiceKeyHeld = false; voice.voiceUp(lang: "zh")
        }
    }
    /// F2 = 返回列表(松手触发,对齐 Android ACTION_UP)。view_ 守卫天然给两条路由去重:第一次触发后
    /// view 变 list,第二条路由再来也被这里挡掉。
    private func backKeyAction(pressed: Bool) {
        if !pressed, view_ == .terminal { backToList() }
    }

    private func pushHwKeyboardState() {
        let present = GCKeyboard.coalesced != nil
        NSLog("[VC] initial hwKeyboard present=\(present)")
        eval("window.setHwKeyboard && window.setHwKeyboard(\(present))")
    }

    // 旋转:SwiftTerm 随 autoresizingMask 重排 → sizeChanged delegate → ssh.resize(自动);列表 webView 走 CSS。
    // 故不再需要手动 syncSize override。

    // MARK: - Voice input (Android VoiceDaemon)
    /// Build the VoiceController once. ASR impl = VolcAsr if asr.json creds present, else MockAsr
    /// (mirrors Android SettingsStore.loadAsr → VolcEngineAsr/MockAsr). Overlay closures eval the
    /// injected window.showOverlay/hideOverlay. Mic recorder is attached lazily after permission.
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
        // inject = write into the live PTY (single-writer SSHSession.send; SPEC §4). nil when no PTY.
        voice.inject = { [weak self] data in self?.ssh?.send(data) }
        // recorder **同步建好**:否则第一次 voiceDown 时 recorder 还 nil(旧 bug:它建在异步权限
        // 回调里,回调比同步的 voiceDown 晚 → 首次录空,第二次才正常)。权限只决定 start 时能否真录到音。
        voice.recorder = AudioCapture()
    }

    /// First voice-key press requests mic permission (Android requests RECORD_AUDIO on first F1).
    /// Granted → attach the AVAudioEngine recorder so the *next* press records. The triggering
    /// press still runs (ASR opens, just no audio that first time) — matches Android's flow.
    private func ensureMicThenRecord() {
        guard !micRequested else { return }
        micRequested = true
        // recorder 已在 setupVoice 同步建好;这里只为首次使用弹权限对话框(已授权则无对话框、立即 granted)。
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            NSLog("[VC] mic permission = \(granted ? "granted" : "DENIED — 语音录不到音")")
        }
    }

    /// Apply the current project's voice context (hotwords + 🎤 marker), mirroring Android's
    /// applyProjectHotwords. nil project (mock / list) → BASE words, marker off.
    private func applyVoiceContext(_ project: ProjectConfig?) {
        if let project {
            voice.hotwords = Hotwords.merge(project.hotwords)
            voice.voiceMarkerEnabled = project.type.isAiAgent
        } else {
            voice.hotwords = Hotwords.base
            voice.voiceMarkerEnabled = false
        }
        NSLog("[VC] voice ctx: hotwords=\(voice.hotwords.count) marker=\(voice.voiceMarkerEnabled) project=\(project?.session ?? "none")")
    }

    // MARK: - helpers
    /// app 自己的状态文案("连接 host…"/"连接失败"/"已断开")写进原生终端。
    private func writeToTerm(_ s: String) {
        term.feed(text: s)
    }

    private func eval(_ js: String) {
        DispatchQueue.main.async {
            guard self.pageReady || js.contains("setHosts") == false else { return }
            self.webView.evaluateJavaScript(js) { _, err in
                if let err { NSLog("[VC] eval error: \(err) for: \(js.prefix(60))") }
            }
        }
    }

    /// JS string literal for an arbitrary string (handles quotes/newlines safely).
    private func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        if let data, let arr = String(data: data, encoding: .utf8) {
            return String(arr.dropFirst().dropLast())   // strip the [ ] → just the quoted scalar
        }
        return "\"\""
    }

    deinit {
        if let o = kbConnectObs { NotificationCenter.default.removeObserver(o) }
        if let o = kbDisconnectObs { NotificationCenter.default.removeObserver(o) }
        if let o = foregroundObs { NotificationCenter.default.removeObserver(o) }
    }
}
