import UIKit
import ObjectiveC.runtime

/// 抑制 WKWebView 终端页的系统软键盘(iOS 等价于 Android 的 `FLAG_ALT_FOCUSABLE_IM`)。
///
/// xterm.js 用一个隐藏 textarea 收输入;它一聚焦(用户点终端),iOS 就弹系统软键盘。但本 app
/// 的终端输入只来自**物理键 / 语音 / SPA 自绘虚拟键盘**,系统 IME 不该冒出来挡屏。
///
/// 手法:把私有类 `WKContentView` 的 `-_requiresKeyboardWhenFirstResponder` 永远改成返回 `false`。
/// 软键盘因此不弹,但该 view **仍能当 first responder 收硬件键事件**(蓝牙键盘 / 物理键照常)。
/// 只影响 WKWebView 文本输入(本 app 唯一的就是终端);native 的 host 配置页/文档选择器不受影响。
enum WebViewKeyboard {
    /// app 启动时调用一次(WKWebView 创建前)。私有类找不到时安静跳过,不崩。
    /// 两刀都要:
    /// ① `_requiresKeyboardWhenFirstResponder` → false:压住系统软键盘本体。
    /// ② `inputAccessoryView` → nil:压住键盘上方那条工具栏(`< > Done`),否则键盘没了它还残留一条窄条。
    static func suppressTerminalIME() {
        guard let cls = NSClassFromString("WKContentView") else { return }

        // ① 软键盘本体:返回 BOOL false
        let kbSel = NSSelectorFromString("_requiresKeyboardWhenFirstResponder")
        let kbBlock: @convention(block) (Any) -> Bool = { _ in false }
        replace(cls, kbSel, imp_implementationWithBlock(kbBlock), types: "B@:")

        // ② 输入工具条:返回 nil(id)
        let accSel = NSSelectorFromString("inputAccessoryView")
        let accBlock: @convention(block) (Any) -> UIView? = { _ in nil }
        replace(cls, accSel, imp_implementationWithBlock(accBlock), types: "@@:")
    }

    private static func replace(_ cls: AnyClass, _ sel: Selector, _ imp: IMP, types: String) {
        if let m = class_getInstanceMethod(cls, sel) {
            method_setImplementation(m, imp)      // 已有 → 替换
        } else {
            class_addMethod(cls, sel, imp, types) // 没有 → 加
        }
    }
}
