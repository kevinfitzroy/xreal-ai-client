import UIKit

/// 终端右缘的"无极拨轮":隐形竖向触摸区,**平时完全不可见(不遮挡正文)**,手指搭上去才显形为
/// 一组**白色横线刻度**(极简,上下淡出做出"轮子卷走"感),滚动时刻度跟手转动 + 逐行
/// `UISelectionFeedbackGenerator`("咔哒")。**对 SwiftTerm/tmux 一无所知**——只把"拖了多少点"换算成行数。
protocol TerminalScrollRailDelegate: AnyObject {
    /// - Parameters:
    ///   - lines: 行数。**>0 = 朝历史(上/旧),<0 = 朝最新(下/新)**(拨轮跟滚动同向)。
    ///   - inertia: 是否惯性阶段(此时 VC 不触发 tmux 深历史接力)。
    /// - Returns: true=已消费(还能继续滚);false=到硬边(rail 停掉惯性)。
    @discardableResult
    func terminalScrollRail(_ rail: TerminalScrollRail, scrollLines lines: Int, inertia: Bool) -> Bool
    func terminalScrollRailDidBegin(_ rail: TerminalScrollRail)
    func terminalScrollRailDidEnd(_ rail: TerminalScrollRail)
}

final class TerminalScrollRail: UIView {
    weak var delegate: TerminalScrollRailDelegate?

    // MARK: 可调常量
    static let hitWidth: CGFloat = 42        // 隐形触摸区(好按)
    private let wheelWidth: CGFloat = 15     // 可见刻度宽
    private let ridgeSpacing: CGFloat = 7    // 横线间距(疏)
    private let lineThickness: CGFloat = 1.6
    private let gain: CGFloat = 1.0
    private let friction: CGFloat = 0.94
    private let minInertiaSpeed: CGFloat = 0.6
    private let maxStepPerFrame = 6

    var lineHeight: CGFloat = 18 { didSet { if lineHeight <= 0 { lineHeight = 18 } } }

    private let wheel = UIView()               // 平时 alpha 0,触摸才显
    private let sheen = CAGradientLayer()       // 极淡中央高光
    private let ridges = CAReplicatorLayer()    // 白色横线(纵向平铺,可滚)
    private let ridgeLine = CALayer()
    private let fade = CAGradientLayer()        // 上下淡出(轮子卷走感)→ 作 wheel.layer.mask
    private let highlight = UIView()            // 触摸点柔光
    private let selection = UISelectionFeedbackGenerator()
    private var link: CADisplayLink?
    private var velocity: CGFloat = 0
    private var residual: CGFloat = 0
    private var lastY: CGFloat = 0
    private var ridgeOffset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        wheel.alpha = 0                         // 平时不可见
        addSubview(wheel)

        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.colors = [UIColor(white: 1, alpha: 0).cgColor,
                        UIColor(white: 1, alpha: 0.06).cgColor,
                        UIColor(white: 1, alpha: 0).cgColor]
        wheel.layer.addSublayer(sheen)

        ridgeLine.backgroundColor = UIColor(white: 1, alpha: 0.92).cgColor   // 白线
        ridges.addSublayer(ridgeLine)
        ridges.instanceTransform = CATransform3DMakeTranslation(0, ridgeSpacing, 0)
        wheel.layer.addSublayer(ridges)

        // 上下淡出:作 wheel 的 mask(竖向 alpha 渐变)
        fade.colors = [UIColor(white: 0, alpha: 0).cgColor,
                       UIColor(white: 0, alpha: 1).cgColor,
                       UIColor(white: 0, alpha: 1).cgColor,
                       UIColor(white: 0, alpha: 0).cgColor]
        fade.locations = [0, 0.15, 0.85, 1]
        wheel.layer.mask = fade

        highlight.alpha = 0
        highlight.isUserInteractionEnabled = false
        highlight.backgroundColor = UIColor(white: 1, alpha: 0.22)
        highlight.layer.cornerRadius = 15
        addSubview(highlight)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(onPan(_:))))
        selection.prepare()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = bounds.maxX - wheelWidth - 7
        let top: CGFloat = 14
        let h = max(0, bounds.height - top * 2)
        wheel.frame = CGRect(x: x, y: top, width: wheelWidth, height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sheen.frame = wheel.bounds
        fade.frame = wheel.bounds
        ridgeLine.frame = CGRect(x: 0, y: 0, width: wheelWidth, height: lineThickness)
        ridges.frame = CGRect(x: 0, y: -ridgeSpacing, width: wheelWidth, height: h + ridgeSpacing * 2)
        ridges.instanceCount = Int(ceil((h + ridgeSpacing * 2) / ridgeSpacing)) + 1
        updateRidges()
        CATransaction.commit()
    }

    /// 横线按 ridgeOffset 滚动(mod 间距,无缝循环)。
    private func updateRidges() {
        var m = ridgeOffset.truncatingRemainder(dividingBy: ridgeSpacing)
        if m < 0 { m += ridgeSpacing }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ridges.frame.origin.y = -ridgeSpacing + m
        CATransaction.commit()
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let y = g.location(in: self).y
        switch g.state {
        case .began:
            stopInertia()
            lastY = y; velocity = 0; residual = 0
            setActive(true, atY: y)
            delegate?.terminalScrollRailDidBegin(self)
        case .changed:
            let dy = y - lastY
            lastY = y
            velocity = dy
            moveGlow(y)
            emit(points: dy, inertia: false)
        case .ended, .cancelled, .failed:
            delegate?.terminalScrollRailDidEnd(self)
            startInertia()
        default:
            break
        }
    }

    /// 点位移→整行,发给 delegate;每次发一下逐格触觉。横线跟手滚动(轮子转)。
    /// 方向 = 拨轮跟滚动同向:手指上拨(points<0)→ 往上滚(历史,lines>0);下拨→ 往下滚(最新,lines<0)。
    @discardableResult
    private func emit(points: CGFloat, inertia: Bool) -> Bool {
        ridgeOffset += points          // 横线跟手指(轮子转)
        updateRidges()
        residual -= points * gain
        var lines = Int(residual / lineHeight)
        if lines == 0 { return true }
        lines = max(-maxStepPerFrame, min(maxStepPerFrame, lines))
        residual -= CGFloat(lines) * lineHeight
        let consumed = delegate?.terminalScrollRail(self, scrollLines: lines, inertia: inertia) ?? false
        selection.selectionChanged()
        selection.prepare()
        return consumed
    }

    private func startInertia() {
        stopInertia()
        guard abs(velocity) >= minInertiaSpeed else { setActive(false, atY: lastY); return }
        let l = CADisplayLink(target: self, selector: #selector(inertiaTick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc private func inertiaTick() {
        velocity *= friction
        if abs(velocity) < minInertiaSpeed { stopInertia(); setActive(false, atY: lastY); return }
        moveGlow(highlight.center.y + velocity)
        if !emit(points: velocity, inertia: true) { stopInertia(); setActive(false, atY: lastY) }
    }
    private func stopInertia() { link?.invalidate(); link = nil }

    /// 平时不可见(alpha 0),触摸淡入显形;松手淡出。
    private func setActive(_ on: Bool, atY y: CGFloat) {
        if on { moveGlow(y) }
        UIView.animate(withDuration: on ? 0.14 : 0.25) {
            self.wheel.alpha = on ? 1 : 0
            self.highlight.alpha = on ? 1 : 0
        }
    }
    private func moveGlow(_ y: CGFloat) {
        let clamped = max(0, min(bounds.height, y))
        highlight.frame = CGRect(x: bounds.maxX - wheelWidth - 12, y: clamped - 15, width: 30, height: 30)
    }
}
