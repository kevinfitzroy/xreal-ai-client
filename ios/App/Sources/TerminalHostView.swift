import UIKit
import SwiftTerm
import ObjectiveC.runtime
import CoreText

/// app 层物理键回调(F1 语音 / F2 返回 / 语音预览态的 Enter·Esc)。其余键全交给 SwiftTerm 自己编码。
protocol TerminalHostKeyHandler: AnyObject {
    func termVoiceKey(down: Bool)   // F1 hold-to-talk(down=按下/抬起)
    func termBackKey()              // F2 → 返回列表
    func termPage(up: Bool)         // Shift+↑/↓ → PageUp/PageDown 给远端 TUI
    func termSend(bytes: [UInt8])   // 少数被中文输入法污染的 ASCII 键,走 raw bytes
    func termVoiceActive() -> Bool  // 语音是否在"应抢 Enter/Esc"的态(overlay 可见)
    func termVoiceEnter() -> Bool   // @return true=语音接管(注入预览文本);false=透传给终端(发 CR)
    func termVoiceEsc() -> Bool     // @return true=语音接管(取消会话);false=透传(发 ESC)
}

/// SwiftTerm `TerminalView` 子类,持 app 键回调。SwiftTerm 把 `pressesBegan` 声明成 **public(非 open)**
/// → 无法在子类 override,故 F1/F2 + 语音 Enter/Esc 的拦截改用 **method swizzle**(见 TerminalKeyInterceptor)。
/// 这是改用原生终端的关键收益:键盘编码(字母/Tab/Shift+Tab/方向/Ctrl/DECCKM…)全交给成熟 VT100 引擎,
/// 不再在 Swift 里重造;只把 app 专用功能键(F1/F2、预览态 Enter/Esc)拦下来。
final class TerminalHostView: TerminalView {
    weak var keyHandler: TerminalHostKeyHandler?

    /// 强制英文输入模式 → 禁掉中文 IME 拼音组字(终端要 raw ASCII 直通)。硬件键盘当前输入源是中文时,
    /// 不覆盖会走 setMarkedText 组字。取系统已装的英文输入模式;没有英文则回退系统默认。
    /// textInputMode 是 UIResponder 的 open 属性,SwiftTerm 只读不覆盖 → 可在此 override(无需 swizzle)。
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("en") ?? false } ?? super.textInputMode
    }
}

/// iOS 原生终端用 SwiftTerm,只能接一个 UIFont,不像 xterm.js 能写 CSS fallback list。
/// 两个 Android 同款字体都注册;实际优先 Sarasa,覆盖 CJK + Nerd/box glyphs 更稳。
enum TerminalFonts {
    static func terminalFont(size: CGFloat) -> UIFont {
        let meslo = registerFont(resource: "meslo-powerline", ext: "otf")
        let sarasa = registerFont(resource: "sarasa-term", ext: "ttf")
        for postScriptName in [sarasa, meslo].compactMap({ $0 }) {
            if let font = UIFont(name: postScriptName, size: size) {
                NSLog("[TerminalFonts] using \(postScriptName)")
                return font
            }
        }
        NSLog("[TerminalFonts] bundled fonts unavailable, falling back to Menlo")
        return UIFont(name: "Menlo", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func registerFont(resource: String, ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "web") else {
            NSLog("[TerminalFonts] missing web/\(resource).\(ext)")
            return nil
        }
        let postScriptName = loadPostScriptName(url: url)
        var err: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err), let err {
            let message = (err.takeRetainedValue() as Error).localizedDescription
            NSLog("[TerminalFonts] register \(resource).\(ext): \(message)")
        }
        return postScriptName
    }

    private static func loadPostScriptName(url: URL) -> String? {
        guard let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider) else { return nil }
        return font.postScriptName as String?
    }
}

/// 在 `TerminalView.pressesBegan/Ended/Cancelled` 上 swizzle 一层:拦 F1/F2 + 语音预览态 Enter/Esc,
/// 其余 press 原样转给 SwiftTerm 原实现。SwiftTerm 的 pressesBegan 会消费 F1/F2(映射成功能键序列),
/// 不会冒泡到 VC → 只能在这一层拦。
enum TerminalKeyInterceptor {
    typealias PressesIMP = @convention(c) (NSObject, Selector, NSSet, UIPressesEvent?) -> Void
    private static var installed = false
    private static var origBegan: PressesIMP?
    private static var origEnded: PressesIMP?
    private static var origCancelled: PressesIMP?

    /// 安装一次(VC 创建终端前调)。
    static func installOnce() {
        guard !installed else { return }
        installed = true
        origBegan = swap(#selector(UIResponder.pressesBegan(_:with:)), down: true) { origBegan }
        origEnded = swap(#selector(UIResponder.pressesEnded(_:with:)), down: false) { origEnded }
        origCancelled = swap(#selector(UIResponder.pressesCancelled(_:with:)), down: false) { origCancelled }
        // 禁中文 IME:keyboardType getter 返回 .asciiCapable(SwiftTerm 原实现返回 .default → 硬件键盘
        // 走拼音组字)。声明只收 ASCII → iOS 不对终端字段组字,字母直通。getter 是 public 非 open,故 swizzle。
        if let m = class_getInstanceMethod(TerminalView.self, NSSelectorFromString("keyboardType")) {
            let kbBlock: @convention(block) (NSObject) -> Int = { _ in UIKeyboardType.asciiCapable.rawValue }
            method_setImplementation(m, imp_implementationWithBlock(kbBlock))
        }
    }

    private static func swap(_ sel: Selector, down: Bool, orig getOrig: @escaping () -> PressesIMP?) -> PressesIMP? {
        guard let m = class_getInstanceMethod(TerminalView.self, sel) else { return nil }
        let orig = unsafeBitCast(method_getImplementation(m), to: PressesIMP.self)
        let block: @convention(block) (NSObject, NSSet, UIPressesEvent?) -> Void = { obj, presses, event in
            guard let host = obj as? TerminalHostView, let kh = host.keyHandler else {
                orig(obj, sel, presses, event); return
            }
            var forward: [UIPress] = []
            for case let p as UIPress in presses {
                if !intercept(p, down: down, handler: kh) { forward.append(p) }
            }
            if forward.isEmpty { return }                 // 全部被 app 拦下 → 不调原实现
            orig(obj, sel, NSSet(array: forward), event)  // 剩余键交给 SwiftTerm 正常处理
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
        return orig
    }

    /// @return true 若 app 拦截(不转发给 SwiftTerm)。
    private static func intercept(_ press: UIPress, down: Bool, handler kh: TerminalHostKeyHandler) -> Bool {
        guard let key = press.key else { return false }
        switch key.keyCode {
        case .keyboardF1: kh.termVoiceKey(down: down); return true
        case .keyboardF2: if down { kh.termBackKey() }; return true
        case .keyboardUpArrow where key.modifierFlags.contains(.shift):
            if down { kh.termPage(up: true) }
            return true
        case .keyboardDownArrow where key.modifierFlags.contains(.shift):
            if down { kh.termPage(up: false) }
            return true
        case .keyboardB, .keyboardC, .keyboard1:
            guard let bytes = asciiFallbackBytes(for: key) else { return false }
            if down { kh.termSend(bytes: bytes) }
            return true
        case .keyboardReturnOrEnter, .keypadEnter:
            // 语音预览态:Enter 确认注入(消费);否则透传给 SwiftTerm 发 CR。两步:注入后 state→idle,
            // 下一个 Enter 时 termVoiceEnter 返回 false → 透传 → 执行命令。
            if down, kh.termVoiceActive(), kh.termVoiceEnter() { return true }
            return false
        case .keyboardEscape:
            if down, kh.termVoiceActive(), kh.termVoiceEsc() { return true }
            return false
        default:
            return false
        }
    }

    /// iOS 硬件键在中文输入源下,少数键的 `characters` 会被 IME 污染。只兜底已确认出问题的键位。
    private static func asciiFallbackBytes(for key: UIKey) -> [UInt8]? {
        let flags = key.modifierFlags
        if flags.contains(.command) || flags.contains(.alternate) { return nil }
        let control = flags.contains(.control)
        let shifted = flags.contains(.shift) != flags.contains(.alphaShift)
        switch key.keyCode {
        case .keyboardB:
            if control { return [0x02] }
            return [shifted ? 0x42 : 0x62]
        case .keyboardC:
            if control { return [0x03] }
            return [shifted ? 0x43 : 0x63]
        case .keyboard1 where shifted && !control:
            return [0x21] // !
        default:
            return nil
        }
    }
}
