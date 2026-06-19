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

    /// **轻量打字输入**(方案二,issue 调研中)。默认 **关**。
    ///
    /// 开 = 终端态可唤起一个覆盖终端的打字 overlay(`TypedInputOverlay`):系统原生键盘 + `inputAccessoryView`
    /// 快捷键条(`/` `?` `!` + `/compact` `/context` 等命令),确认后整段经 `sendToActivePTY` 注入。
    /// **关键:打字态冻结 `term.frame`**(旁路键盘避让)→ 不触发 PTY resize / tmux 重绘。
    ///
    /// opt-in 原因:触发方式 + 送出语义未定(见 issue),且未上机测。改 `true` 重编可试。
    static let typedInput = false
}
