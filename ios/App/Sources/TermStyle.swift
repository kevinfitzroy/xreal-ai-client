import UIKit

/// bash(终端)页 chrome 的统一视觉 token。**只管终端页的外围控件**(迷你条 / 抽屉 / 语音卡 / 录音条 /
/// 拨轮 / 状态条 / 新消息药丸 / 安全区底)——列表 / Home / 日志 / Host 管理不用这套。
/// 终端正文配色见 `TerminalViewController.configureTerminalTheme`(本次不动)。
enum TermStyle {
    private static func hex(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    // 底色家族(由浅到深)
    static let term     = hex(0x28, 0x29, 0x2b)   // 终端正文底 + 安全区底(= 原 terminalBackgroundColor)
    static let chrome   = hex(0x1b, 0x1e, 0x24)   // 迷你条 / 录音条
    static let surface  = hex(0x16, 0x18, 0x1d)   // 抽屉 / 语音卡

    static let border   = hex(0x2e, 0x33, 0x3b)
    static let ink      = hex(0xe6, 0xe9, 0xef)
    static let muted    = hex(0x8a, 0x90, 0x9a)

    static let accent   = hex(0x34, 0xc7, 0x77)   // 强调绿(mic / 关键动作)
    static let danger   = hex(0xc0, 0x39, 0x2b)   // Break / 录音结束

    // 按键
    static let keyBg     = UIColor(white: 1, alpha: 0.09)
    static let keyBorder = UIColor(white: 1, alpha: 0.15)
    static let keyHighlight = UIColor(white: 1, alpha: 0.30)
    // 方向键(蓝调,与功能键区分)
    static let arrowBg     = UIColor(red: 0.30, green: 0.40, blue: 0.60, alpha: 0.18)
    static let arrowBorder = UIColor(red: 0.36, green: 0.44, blue: 0.60, alpha: 1)
    static let arrowInk    = hex(0xcf, 0xe0, 0xff)
    // Break(红调)
    static let dangerBg     = UIColor(red: 0.75, green: 0.22, blue: 0.17, alpha: 0.18)
    static let dangerBorder = UIColor(red: 0.66, green: 0.22, blue: 0.18, alpha: 1)
    static let dangerInk    = hex(0xff, 0xb9, 0xb1)

    static let grab = UIColor(white: 0.42, alpha: 1)

    // 度量
    static let radius: CGFloat = 12      // 条 / 卡
    static let keyRadius: CGFloat = 10   // 键
    static let space: CGFloat = 8
}

/// 复用触感发生器(预热好,降低首次延迟)。
enum Haptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let soft = UIImpactFeedbackGenerator(style: .soft)
    static func prepareAll() { light.prepare(); soft.prepare() }
}

extension UIButton {
    /// 按压反馈:按下=轻触感 + 缩放 0.93,松手=弹簧回弹。尊重「减弱动态」。
    func addPressFX() {
        addAction(UIAction { [weak self] _ in
            Haptics.light.impactOccurred()
            self?.pressFX(down: true)
        }, for: .touchDown)
        let up = UIAction { [weak self] _ in self?.pressFX(down: false) }
        addAction(up, for: .touchUpInside)
        addAction(up, for: .touchUpOutside)
        addAction(up, for: .touchCancel)
        addAction(up, for: .touchDragExit)
    }

    func pressFX(down: Bool) {
        if UIAccessibility.isReduceMotionEnabled {
            transform = down ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            return
        }
        UIView.animate(withDuration: down ? 0.07 : 0.30, delay: 0,
                       usingSpringWithDamping: down ? 1 : 0.55, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = down ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
        }
    }
}
