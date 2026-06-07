import Foundation

/// 编译期功能开关:改这里的常量、重新编译即生效(`static let` 常量被编译器作死代码消除,关时不进运行路径)。
enum BuildFeatures {
    /// 终端右缘**无极拨轮**(issue #24)。默认 **关**。
    ///
    /// 关(默认)= 现有**点击半屏翻页**(点上半屏=上、中段=下,发 Shift+↑/↓ 给 tmux copy-mode)。
    /// 开 = 右缘隐形拨轮:本地 SwiftTerm 缓冲连续丝滑滚 → 触顶接力 tmux 深历史 → 底部"新消息"药丸。
    ///
    /// 做成可选的原因:拨轮要连续滚 + 触顶时按行发 SSH 接力 tmux,**网络差时可能卡/抖**;
    /// 点击翻页一次一格、一次 SSH 往返,弱网更稳。需要时把下面改成 `true` 重编。
    /// 见 [`ios/README.md`](../../README.md) 「拨轮(可选)」。
    static let scrollRail = false
}
