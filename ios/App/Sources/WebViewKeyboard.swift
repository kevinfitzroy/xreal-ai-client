import UIKit
import ObjectiveC.runtime

/// 抑制 WKWebView 终端页的系统软键盘(iOS 等价于 Android 的 `FLAG_ALT_FOCUSABLE_IM`),
/// **同时保留硬件键盘的 DOM 投递**(xterm.js 自己编码所有终端键 —— Option B 架构)。
///
/// xterm.js 用一个隐藏 textarea 收输入;它一聚焦,iOS 弹系统软键盘。本 app 终端输入来自**物理键盘 /
/// 语音 / SPA 自绘虚拟键盘**,系统 IME 不该冒出来挡屏,且 IME 激活会截走 Enter/组合键。
///
/// **手法**:swizzle `WKContentView._requiresKeyboardWhenFirstResponder` → `false`,压住系统软键盘本体。
/// 这是标准的"藏软键盘、留硬件键盘"手法。⚠️ **关键前提**:硬件键要进 DOM,WKWebView 必须真的成为
/// first responder —— iOS 上 JS `term.focus()` 在无用户手势时**不会**让原生 view 成 first responder,
/// 全程键盘导航又没人"点"终端 → 所以 TerminalViewController 进终端时**原生 `webView.becomeFirstResponder()`**。
/// (此前误判此 swizzle 切断 DOM 投递;实测真正变量是 becomeFirstResponder,swizzle 只管藏键盘。)
/// 只影响 WKWebView(本 app 唯一文本输入是终端);native 的文档选择器不受影响。
enum WebViewKeyboard {
    /// app 启动时调用一次(WKWebView 创建前)。私有类找不到时安静跳过,不崩。两刀:
    /// ① `_requiresKeyboardWhenFirstResponder` → false:压住系统软键盘本体(保留硬件键,配合 becomeFirstResponder)。
    /// ② `inputAccessoryView` → nil:压住键盘上方那条工具栏(`< > Done`),否则残留一条窄条。
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
