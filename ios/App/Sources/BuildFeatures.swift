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

    /// **轻量打字输入**(方案二,#32)。默认 **开**(已真机验证)。
    ///
    /// 终端态**双指轻点**唤起覆盖终端的打字 overlay(`TypedInputOverlay`):系统原生键盘 + `inputAccessoryView`
    /// 多行快捷键条(`/` `?` `!` + `/compact` `/context` 等命令),送出后整段经 `sendToActivePTY` 注入。
    /// **关键:打字态钉死 `term.frame`** → 不触发 PTY resize / tmux 重绘。
    ///
    /// 决策(#32):送出**不加 `\n`**(注入后用户复核、再按 Enter 执行,同语音安全网)。
    static let typedInput = true
}
