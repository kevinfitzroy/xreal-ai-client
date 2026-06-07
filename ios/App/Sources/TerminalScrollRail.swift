import UIKit

/// 终端右缘的"无极拨轮":一条隐形竖向触摸区,手指搭上去才显形,上下拖 = 连续滚,松手有惯性,
/// 逐行 `UISelectionFeedbackGenerator`("咔哒",同 iOS 选时间滚轮)。**对 SwiftTerm/tmux 一无所知**——
/// 只把"拖了多少点"换算成整行数发给 delegate,具体怎么滚(本地缓冲 / tmux 深历史)由 VC 决定。
protocol TerminalScrollRailDelegate: AnyObject {
    /// - Parameters:
    ///   - lines: 行数。**>0 = 朝历史(上/旧),<0 = 朝最新(下/新)**(内容跟手指:手指下移→看历史)。
    ///   - inertia: 是否惯性阶段(此时 VC 不触发 tmux 深历史接力,避免高速狂发 SSH)。
    /// - Returns: true=已消费(还能继续滚);false=到硬边(rail 停掉惯性)。
    @discardableResult
    func terminalScrollRail(_ rail: TerminalScrollRail, scrollLines lines: Int, inertia: Bool) -> Bool
    func terminalScrollRailDidBegin(_ rail: TerminalScrollRail)
    func terminalScrollRailDidEnd(_ rail: TerminalScrollRail)
}

final class TerminalScrollRail: UIView {
    weak var delegate: TerminalScrollRailDelegate?

    // MARK: 可调常量(真机调手感)
    /// 隐形触摸区宽度(比可见条宽很多,好按又不误触)。VC 按此宽贴在终端右缘。
    static let hitWidth: CGFloat = 42
    private let visWidth: CGFloat = 5
    private let gain: CGFloat = 1.0              // 手指位移→内容位移倍率(1.0=跟手)
    private let friction: CGFloat = 0.94         // 惯性每帧衰减
    private let minInertiaSpeed: CGFloat = 0.6   // 点/帧,低于此停惯性
    private let maxStepPerFrame = 6              // 单次最多滚几行(防 teleport 爆冲)

    /// 一行的像素高(VC 按 term.frame.height / rows 设进来),拖动距离按它换算行数。
    var lineHeight: CGFloat = 18 {
        didSet { if lineHeight <= 0 { lineHeight = 18 } }
    }

    private let visBar = UIView()
    private let visGradient = CAGradientLayer()
    private let glow = UIView()
    private let selection = UISelectionFeedbackGenerator()
    private var link: CADisplayLink?
    private var velocity: CGFloat = 0    // 点/帧(末次拖动速度,带方向)
    private var residual: CGFloat = 0    // 不足一行的点累积
    private var lastY: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        // 可见竖条:很窄,两端渐隐,平时 alpha=0,触摸时淡入。
        visBar.alpha = 0
        visBar.layer.cornerRadius = visWidth / 2
        visBar.clipsToBounds = true
        let blue = UIColor(red: 0.54, green: 0.65, blue: 1, alpha: 1)
        visGradient.colors = [blue.withAlphaComponent(0).cgColor,
                              blue.withAlphaComponent(0.85).cgColor,
                              blue.withAlphaComponent(0).cgColor]
        visGradient.locations = [0, 0.5, 1]
        visBar.layer.addSublayer(visGradient)
        addSubview(visBar)

        // 跟手指的柔光团。
        glow.alpha = 0
        glow.isUserInteractionEnabled = false
        glow.backgroundColor = UIColor(red: 0.47, green: 0.66, blue: 1, alpha: 0.32)
        glow.layer.cornerRadius = 15
        glow.layer.shadowColor = UIColor(red: 0.47, green: 0.66, blue: 1, alpha: 1).cgColor
        glow.layer.shadowRadius = 9
        glow.layer.shadowOpacity = 0.9
        glow.layer.shadowOffset = .zero
        addSubview(glow)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        addGestureRecognizer(pan)
        selection.prepare()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        visBar.frame = CGRect(x: bounds.maxX - visWidth - 7, y: 10, width: visWidth, height: max(0, bounds.height - 20))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        visGradient.frame = visBar.bounds
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

    /// 点位移→整行,发给 delegate;每次发一下逐格触觉。内容跟手指:手指下移(points>0)→ 朝历史(lines>0)。
    @discardableResult
    private func emit(points: CGFloat, inertia: Bool) -> Bool {
        residual += points * gain
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
        let glowY = (glow.frame.midY + velocity)
        moveGlow(glowY)
        if !emit(points: velocity, inertia: true) { stopInertia(); setActive(false, atY: lastY) }
    }
    private func stopInertia() { link?.invalidate(); link = nil }

    private func setActive(_ on: Bool, atY y: CGFloat) {
        if on { moveGlow(y) }
        UIView.animate(withDuration: 0.18) {
            self.visBar.alpha = on ? 1 : 0
            self.glow.alpha = on ? 1 : 0
        }
    }
    private func moveGlow(_ y: CGFloat) {
        let clamped = max(0, min(bounds.height, y))
        glow.frame = CGRect(x: bounds.maxX - 30, y: clamped - 15, width: 30, height: 30)
    }
}
