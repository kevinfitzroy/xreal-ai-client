import UIKit
import WebKit
import GameController

/// Phase 1 core-loop controller. Mirrors Android's MainActivity:
///   hosts.json → Agent Deck list → openProject → SSH(ed25519) PTY terminal → back.
///
/// Full-screen WKWebView hosting the *unmodified-shared* `index.html` (Agent Deck SPA).
/// `window.Bridge` is injected as a WKUserScript forwarding to `messageHandlers.bridge`.
final class TerminalViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    // 全屏沉浸(AR 眼镜场景):隐藏状态栏(时间/电量/信号)+ home indicator = Android immersive。
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private var webView: WKWebView!
    private var pageReady = false

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
            ssh?.send(Data([13]))   // CR — the shim routes Enter here, native must write it
        case "vkeyEsc":
            ssh?.send(Data([27]))   // ESC
        case "voiceDown", "voiceUp":
            break   // voice is out of Phase 1
        default:
            NSLog("[VC] bridge msg \(m) \(a)")
        }
    }

    // MARK: - Open project → PTY
    private func onOpenProject(host: String, session: String, name: String, type: String) {
        NSLog("[VC] openProject host=\(host) session=\(session)")
        let seq = { openSeq += 1; return openSeq }()
        view_ = .terminal
        eval("window.showTerminal(\(jsString(name)), \(jsString(type)))")

        guard let h = hosts.first(where: { $0.name == host }),
              let p = (h.projects.first(where: { $0.session == session })) else {
            // mock / unconfigured — nothing to connect to; stay on the (empty) terminal.
            writeToTerm("\r\n[no SSH config for \(session)]\r\n")
            return
        }
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
                self.eval("window.writeToTerm('\(data.base64EncodedString())')")
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
                    // Re-push the current xterm size: showTerminal's fit fired before the
                    // PTY existed, so the PTY would stay 80×24 and tmux wouldn't fill.
                    self.eval("window.syncSize && window.syncSize()")
                    #if DEBUG
                    // self-verify the keystroke path (JS Bridge.onInput → eventStream .data
                    // → outbound.write → PTY → echo → render). Routes through the SAME bridge
                    // a real keypress uses, not a raw ssh.send.
                    if ProcessInfo.processInfo.arguments.contains("-autoTypeAfterOpen") {
                        let cmd = "echo XREAL_OK\n"
                        let b64 = Data(cmd.utf8).base64EncodedString()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.eval("window.Bridge.onInput('\(b64)')")
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
        openSeq += 1     // in-flight connections are now obsolete
        sessionGen += 1  // late output chunks are now obsolete
        view_ = .list
        let old = ssh
        ssh = nil
        old?.close()     // finishes stream + closes client → PTY loop exits, tmux persists
        eval("window.showList()")
        refreshManifests()   // a project Maestro just created shows up now
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
        guard pageReady else { return }   // didFinish will seed+refresh once loaded
        // If a file is opened while a PTY is live (background → "Open in" → foreground in terminal),
        // tear the session down before switching to the list — otherwise onOutput keeps painting a
        // hidden xterm and the tmux attach leaks (bump openSeq/sessionGen so late chunks no-op).
        if view_ == .terminal {
            openSeq += 1; sessionGen += 1
            let old = ssh; ssh = nil; old?.close()
        }
        if view_ != .list { view_ = .list; eval("window.showList()") }
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
            self?.eval("window.setHwKeyboard && window.setHwKeyboard(true)")
        }
        kbDisconnectObs = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            NSLog("[VC] GCKeyboard disconnected → show vkey")
            self?.eval("window.setHwKeyboard && window.setHwKeyboard(false)")
        }
    }

    private func pushHwKeyboardState() {
        let present = GCKeyboard.coalesced != nil
        NSLog("[VC] initial hwKeyboard present=\(present)")
        eval("window.setHwKeyboard && window.setHwKeyboard(\(present))")
    }

    // MARK: - Orientation → terminal reflow (SPEC §6.1)
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            // After rotation the WKWebView resized → xterm's resize listener fits and
            // emits onResize; syncSize also re-pushes to the live PTY. Belt-and-braces.
            self?.eval("window.syncSize && window.syncSize()")
        }
    }

    // MARK: - helpers
    private func writeToTerm(_ s: String) {
        eval("window.writeToTerm('\(Data(s.utf8).base64EncodedString())')")
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
