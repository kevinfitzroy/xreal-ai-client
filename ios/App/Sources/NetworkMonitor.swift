import Foundation
import Network

/// iOS 网络路径监控：感知 WiFi ↔ 蜂窝切换、断网→恢复，通知 TerminalViewController
/// 主动重建 SSH 连接，不等 TCP 超时。
///
/// 用法：`NetworkMonitor.shared.start()` 在 AppDelegate 启动时调一次；
/// 其他模块监听 `Notification.Name.networkPathChanged`（userInfo = `["available": Bool, "isExpensive": Bool]`）。
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    /// 网络状态变化通知。userInfo: "available"=Bool, "isExpensive"=Bool(蜂窝=昂贵链路)。
    static let pathChangedNotification = Notification.Name("NetworkMonitor.pathChanged")

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "network.monitor")
    private(set) var isAvailable = false
    private(set) var isExpensive = false
    /// 当前接口类型描述（调试用）。
    private(set) var interfaceKind: String = "unknown"
    private var started = false

    private init() {}

    /// 幂等:重复调用是 no-op(NWPathMonitor.start 不能调两次)。由 AppDelegate 启动时调一次。
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let prevAvailable = self.isAvailable
            let prevExpensive = self.isExpensive
            self.isAvailable = path.status == .satisfied
            self.isExpensive = path.isExpensive

            // 接口类型（取第一个可用接口）。
            if let first = path.availableInterfaces.first {
                switch first.type {
                case .wifi:      self.interfaceKind = "wifi"
                case .cellular:  self.interfaceKind = "cellular"
                case .wiredEthernet: self.interfaceKind = "wired"
                case .loopback:  self.interfaceKind = "loopback"
                case .other:     self.interfaceKind = "other"
                @unknown default: self.interfaceKind = "unknown"
                }
            } else {
                self.interfaceKind = "none"
            }

            // 仅当 available / expensive 真变化时才 post(降噪)。否则弱网抖动会让 NWPathMonitor
            // 反复回调同一状态,下游 onNetworkPathChanged 反复重置重连计数 → 击穿上限无限重连(issue #10)。
            guard self.isAvailable != prevAvailable || self.isExpensive != prevExpensive else { return }
            NSLog("[NetworkMonitor] path changed: available=\(self.isAvailable) expensive=\(self.isExpensive) if=\(self.interfaceKind)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.pathChangedNotification,
                    object: self,
                    userInfo: ["available": self.isAvailable, "isExpensive": self.isExpensive]
                )
            }
        }
        monitor.start(queue: queue)
        NSLog("[NetworkMonitor] started")
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
        NSLog("[NetworkMonitor] stopped")
    }
}
