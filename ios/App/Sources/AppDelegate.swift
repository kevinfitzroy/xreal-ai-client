import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = TerminalViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// Convenience accessor for the single root VC (no SceneDelegate; manual UIWindow).
    private var terminalVC: TerminalViewController? {
        window?.rootViewController as? TerminalViewController
    }

    // MARK: - "Open in XrealPOC" import (SPEC §8 real-device channel)
    /// A `.xrhosts` file AirDropped (or shared) into the app arrives here. AirDrop copies it into
    /// `Documents/Inbox/`; a document-picker / Files share may pass a security-scoped URL. We
    /// unpack the self-contained bundle into private storage (HostStore.importConfig) and tell the
    /// VC to reload the list so the new host(s) appear without a relaunch. Best-effort delete the
    /// Inbox copy afterward (we already persisted what we need).
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        NSLog("[AppDelegate] open url: \(url.lastPathComponent)")
        // Inbox/container URLs return false here (already inside our sandbox) — NOT a failure; only
        // a true return means we must stop accessing afterward. Proceed regardless.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try HostStore.importConfig(from: url)
            terminalVC?.reloadHostsAfterImport(imported: result.hosts)
            // Inbox copy no longer needed (config persisted to hosts.json + keys/).
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            return true
        } catch {
            NSLog("[AppDelegate] import failed: \(error)")
            terminalVC?.reportImportFailure("\(error)")
            return false
        }
    }
}
