import UIKit
import WebKit

/// Full-screen WKWebView hosting the *unmodified* Android `index.html` (Agent Deck SPA).
/// Reproduces the SPEC.md bridge contract on iOS by injecting `window.Bridge` as a
/// WKUserScript that forwards to `window.webkit.messageHandlers.bridge`.
final class TerminalViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    private var webView: WKWebView!
    /// Set when M2 SSH succeeds — input is routed to the live PTY instead of echoed.
    private var ssh: SSHSession?
    private var echoMode = true   // M1: native echoes onInput back via writeToTerm

    // MARK: - Bridge shim injected at document start.
    // index.html calls window.Bridge.{onInput,onResize,openProject,...}; we forward
    // each to the bridge message handler. Every method index.html *might* call is
    // defined so the SPA's `if(window.Bridge && window.Bridge.x)` guards all pass.
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

    // Capture JS console + uncaught errors -> native. This is the POC's primary
    // instrument: a screenshot can't reveal silent addon/font failures.
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
        // Enable WebGL access for xterm's webgl addon under file:// origin.
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        view.addSubview(webView)

        guard let webDir = Bundle.main.url(forResource: "web", withExtension: nil) else {
            NSLog("[POC] FATAL: web/ folder not found in bundle")
            return
        }
        let indexURL = webDir.appendingPathComponent("index.html")
        NSLog("[POC] loading \(indexURL.path)")
        // Grant read access to the whole web/ dir so @font-face file:// urls + addon
        // <script src> resolve (this is exactly the iOS cross-origin question to test).
        webView.loadFileURL(indexURL, allowingReadAccessTo: webDir)
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[POC] index.html loaded; driving M1 demo")
        runM1Demo()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[POC] navigation FAILED: \(error)")
    }

    // MARK: - M1 demo: open terminal, wait for term, write banner, then echo test.
    private func runM1Demo() {
        // 1. Switch the SPA to the terminal view (creates xterm after fontReady).
        eval("showTerminal('iOS POC','ssh')")

        // 2. Try M2 SSH; if it connects, route input to PTY. Otherwise stay in echo.
        attemptSSH()

        // 3. Poll until `term` exists (initTerm is deferred on document.fonts.load),
        //    then write banner + run the echo round-trip. Writing earlier = silent drop.
        waitForTerm { [weak self] in
            guard let self else { return }
            if self.ssh == nil {
                self.writeBanner()
                // Fire an echo round-trip through JS->native->JS to prove the bridge.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let b64 = Self.b64Utf8("echo via bridge: hello\r\n")
                    NSLog("[POC] simulating Bridge.onInput for echo test")
                    self.eval("window.Bridge.onInput('\(b64)')")
                }
            }
        }
    }

    private func waitForTerm(attempt: Int = 0, _ done: @escaping () -> Void) {
        if attempt > 40 { NSLog("[POC] term never appeared after 8s"); done(); return }
        webView.evaluateJavaScript("(window.term ? 1 : (typeof term!=='undefined' && term ? 1 : 0))") { [weak self] res, _ in
            // `term` is a module-scope let, not on window; probe via a helper instead.
            self?.webView.evaluateJavaScript("(function(){ try { return (typeof term!=='undefined' && term) ? 1 : 0; } catch(e){ return 0; } })()") { r2, _ in
                if (r2 as? Int) == 1 || (r2 as? NSNumber)?.intValue == 1 {
                    NSLog("[POC] term ready after \(attempt) polls")
                    done()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self?.waitForTerm(attempt: attempt + 1, done)
                    }
                }
            }
            _ = res
        }
    }

    private func writeBanner() {
        let banner = "\u{1b}[1;32mXREAL iOS POC\u{1b}[0m — WKWebView + xterm.js bridge\r\n" +
                     "Base64 bridge live. Type to echo.\r\n\r\n$ "
        eval("writeToTerm('\(Self.b64Utf8(banner))')")
    }

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
            guard let b64 = a.first as? String else { return }
            handleInput(b64)
        case "onResize":
            let cols = (a.first as? NSNumber)?.intValue ?? 0
            let rows = (a.count > 1 ? a[1] as? NSNumber : nil)?.intValue ?? 0
            NSLog("[POC] onResize \(cols)x\(rows)")
            ssh?.resize(cols: cols, rows: rows)
        case "openProject":
            NSLog("[POC] openProject \(a)")
        default:
            NSLog("[POC] bridge msg \(m) \(a)")
        }
    }

    private func handleInput(_ b64: String) {
        if let ssh = ssh {
            // M2: forward keystrokes to the live PTY; remote shell echoes back.
            if let data = Data(base64Encoded: b64) { ssh.send(data) }
        } else if echoMode {
            // M1: echo the exact same bytes back through writeToTerm (full round-trip).
            NSLog("[POC] echo onInput -> writeToTerm (\(b64))")
            eval("writeToTerm('\(b64)')")
        }
    }

    // MARK: - M2 SSH
    private func attemptSSH() {
        SSHSession.connect(
            onConnected: { [weak self] session in
                DispatchQueue.main.async {
                    guard let self else { return }
                    NSLog("[POC] M2 SSH connected — routing to live PTY")
                    self.ssh = session
                    self.echoMode = false
                    session.onOutput = { [weak self] data in
                        DispatchQueue.main.async {
                            self?.eval("writeToTerm('\(data.base64EncodedString())')")
                        }
                    }
                }
            },
            onFailure: { err in
                NSLog("[POC] M2 SSH unavailable: \(err) — staying in M1 echo mode")
            }
        )
    }

    // MARK: - helpers
    private func eval(_ js: String) {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js) { _, err in
                if let err { NSLog("[POC] eval error: \(err) for: \(js.prefix(60))") }
            }
        }
    }

    /// btoa(unescape(encodeURIComponent(s))) equivalent: UTF-8 -> base64.
    static func b64Utf8(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }
}
