import Foundation

/// 每个 host 的「启用/巡检」开关 —— **客户端本地、人为开闭、持久化**(SPEC §15)。
///
/// 关 = 该 host **不被 manifest 刷新 / 舰队巡检自动连接**(给不常用的 host"停用",避免后台不停触发连接)。
/// 这是**人的观点**,不是 host 下发的状态,所以**不进 hosts.json**(那个会被配置重导覆盖),而是单独按
/// host name 存本地;配置重导后仍保留。**默认开**(缺省 = 启用);手动开 project 不受此开关影响。
enum HostEnabledStore {
    private static let key = "xreal.host.disabled"   // 只记"停用"集合(默认开 → 新 host 自动启用,存得少)

    private static func disabledSet() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isEnabled(_ host: String) -> Bool { !disabledSet().contains(host) }

    static func setEnabled(_ host: String, _ on: Bool) {
        var d = disabledSet()
        if on { d.remove(host) } else { d.insert(host) }
        UserDefaults.standard.set(Array(d), forKey: key)
    }
}
