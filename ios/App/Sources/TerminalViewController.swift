import UIKit
import WebKit
import GameController

/// Phase 1 core-loop controller. Mirrors Android's MainActivity:
///   hosts.json → Agent Deck list → openProject → SSH(ed25519) PTY terminal → back.
///
/// Full-screen WKWebView hosting the *unmodified-shared* `index.html` (Agent Deck SPA).
/// `window.Bridge` is injected as a WKUserScript forwarding to `messageHandlers.bridge`.
final class TerminalViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

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
    // GameController keyboard observers (hardware keyboard → hide vkey, SPEC §6.1).
    private var kbConnectObs: NSObjectProtocol?
    private var kbDisconnectObs: NSObjectProtocol?

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
    }

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

    // MARK: - List push + manifest refresh
    /// Push the current deck to the list view, merging the last-known live status.
    /// `loading:true` (initial, pre-fetch) shows spinners and omits state (reachable=nil).
    private func pushHostList(loading: Bool = false) {
        let json = DeckJSON.hostsArray(
            hosts, loading: loading,
            statusByHost: statusByHost,
            reachable: loading ? nil : reachable   // loading push = unprobed → no state yet
        )
        eval("window.setHosts(\(jsString(json)))")
    }

    /// Fetch each host's manifest + status off the main actor, then re-push the real
    /// list with live state badges. Runs on initial list entry and on back-to-list.
    private func refreshManifests() {
        let snapshot = hosts
        Task {
            let result = await ManifestFetcher.fetch(snapshot)
            await MainActor.run {
                self.hosts = result.hosts
                self.statusByHost = result.statusByHost
                self.reachable = result.reachable
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
        writeToTerm("连接 \(h.name) … (\(p.session))\r\n")   // alias, never the real IP

        let gen = { sessionGen += 1; return sessionGen }()
        let s = SSHSession()
        s.onOutput = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.sessionGen == gen else { return }   // late chunk from closed session
                self.eval("window.writeToTerm('\(data.base64EncodedString())')")
            }
        }
        s.connect(host: h, session: p.session, cols: 80, rows: 24,
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
    }
}
