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
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        CrashReporter.install()   // NSException 捕获 + 启动重喷(issue #35;signal 方案因独立启动白屏已撤)
        // (iOS 全面原生化后无 WKWebView,旧的 WebViewKeyboard 软键盘抑制 swizzle 已无意义,移除。)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.overrideUserInterfaceStyle = .dark   // 全局深色 console 风(终端本就深色,列表/Home 一致 + 科技感)
        let nav = DeckNavController(rootViewController: TerminalViewController())
        nav.navigationBar.prefersLargeTitles = true
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
        NetworkMonitor.shared.start()   // app 级网络监控,单一启动点(幂等)
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

    // MARK: - 后台保活(issue #34):切后台申请有限执行窗口(iOS 约 30s),让 SSH/PTY/xray 在窗口内不被
    // 立刻冻结 → 短暂切走(看通知/回消息)再切回时连接还活着;窗口耗尽或回前台后若已断,走现有优雅重连。
    // ⚠️ 做不到长时间后台驻留(iOS 模型硬约束);只把"切个微信回来终端就死"改善成"短暂切走能续上"。
    func applicationDidEnterBackground(_ application: UIApplication) {
        bgTask = application.beginBackgroundTask(withName: "keep-ssh-warm") { [weak self] in
            self?.endBgTask()   // expiration:窗口耗尽,必须自己结束 task,否则被强杀
        }
        AgentLog.info("app", "enter background, bgTask granted=\(bgTask != .invalid)")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        endBgTask()   // 回前台不再需要后台预算(终端态主动重连在 TerminalViewController 前台观察者里)
    }

    private func endBgTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AgentLog.info("app", "terminate: stop xray tunnels")
        SingboxProxy.stopAll()
    }
}
