import UIKit

/// 导航容器:大标题「Agent Station」列表(苹果原生设计语言)。状态栏/home indicator **交给顶层 VC** 决定
/// (列表态显示、终端态全屏隐藏)。
final class DeckNavController: UINavigationController {
    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // (iOS 全面原生化后无 WKWebView,旧的 WebViewKeyboard 软键盘抑制 swizzle 已无意义,移除。)
        let window = UIWindow(frame: UIScreen.main.bounds)
        let nav = DeckNavController(rootViewController: TerminalViewController())
        nav.navigationBar.prefersLargeTitles = true
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
        AgentLog.info("app", "launch")
        return true
    }

    /// Convenience accessor for the single root VC(包在 DeckNavController 里)。
    private var terminalVC: TerminalViewController? {
        (window?.rootViewController as? UINavigationController)?.viewControllers.first as? TerminalViewController
    }

    // MARK: - "Open in Agent Station" import (SPEC §8 real-device channel)
    /// A `.xrhosts` file AirDropped (or shared) into the app arrives here. AirDrop copies it into
    /// `Documents/Inbox/`; a document-picker / Files share may pass a security-scoped URL. We
    /// unpack the self-contained bundle into private storage (HostStore.importConfig) and tell the
    /// VC to reload the list so the new host(s) appear without a relaunch. Best-effort delete the
    /// Inbox copy afterward (we already persisted what we need).
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        NSLog("[AppDelegate] open url: \(url.lastPathComponent)")
        AgentLog.info("config", "open import file \(url.lastPathComponent)")
        // Inbox/container URLs return false here (already inside our sandbox) — NOT a failure; only
        // a true return means we must stop accessing afterward. Proceed regardless.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try HostStore.importConfig(from: url)
            terminalVC?.reloadHostsAfterImport(result)
            // Inbox copy no longer needed (config persisted to hosts.json + keys/).
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            return true
        } catch {
            NSLog("[AppDelegate] import failed: \(error)")
            AgentLog.error("config", "import failed: \(error)")
            terminalVC?.reportImportFailure("\(error)")
            return false
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AgentLog.info("app", "terminate: stop xray tunnels")
        XrayProxy.stopAll()
    }
}
