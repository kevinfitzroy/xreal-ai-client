# 语音 + 底部控件(常驻条 + 抓柄抽屉)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 把 iOS 终端底部控件重构成「常驻迷你条(Esc · 🎤按住说话 · ⏎ · 抓柄)+ 抓柄上滑展开的 3×3 抽屉」,🎤 取代隐形语音热区(可发现 + 按住上滑转长录音),删隐形热区。

**Architecture:** 迷你条仍是 SwiftTerm 的 `inputAccessoryView`(复用现有显隐/键盘避让/硬件键盘自动隐藏机制)。🎤 的「按住+上滑」由 mic 上的 `UILongPressGestureRecognizer` 实现——手势在 mic 上 begin 后会**全局跟踪**手指(滑出 accessory 进终端区也继续 .changed),故无跨窗口问题,直接复用现有 armed/`lockVoiceToRecording` 逻辑。抽屉是 VC 管理的覆盖层,抓柄 pan 拉起。每个 Phase 保持 app 可编译可用。

**Tech Stack:** Swift / UIKit / SwiftTerm;XcodeGen;`JAVA_HOME=""` 走默认 JDK(iOS 不需要 Android JDK);模拟器编译验证 + 真机功能验证(无单测覆盖 UI 手势)。

**验证基线命令**(每个 build 步骤用):
```bash
cd ios && xcodegen generate >/dev/null && \
JAVA_HOME="" xcodebuild -project XrealPOC.xcodeproj -scheme "Agent Station" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedData build 2>&1 | \
  grep -iE "error:|BUILD (SUCC|FAIL)" | tail -8
```
期望:`** BUILD SUCCEEDED **`。

> ⚠️ UI/手势/录音的真实手感**只能真机验**(模拟器进不了终端态);各 Phase 标注「真机待验」。本计划不打 TestFlight(用户要求 item 1 风格统一后再一次性打)。

---

## File Structure

- **Modify** `ios/App/Sources/TerminalKeyBar.swift` — 从「11 键满铺」重构为**迷你条**:`Esc · 🎤 · ⏎` + 抓柄。新增 voice 按钮 + 抓柄,新增回调 `onVoiceGesture` / `onHandlePan`;`Esc/Enter` 仍走 `onAction`。
- **Create** `ios/App/Sources/TerminalDrawer.swift` — VC 管理的上拉抽屉覆盖层:3×3 网格(剩余 9 个 `TerminalKeyAction`),顶部抓柄,开/合动画,`onAction` 回调,点外部/下滑收起。
- **Modify** `ios/App/Sources/TerminalViewController.swift` — 接迷你条语音手势(从 `handleTermVoicePress` 迁过来的 armed/上滑逻辑)+ 抓柄→抽屉开合 + 抽屉实例/显隐;删 `terminalTouchZone` 的 `.voice` 分支与终端正文上的语音长按。
- **Touch (minimal)** `ios/App/Sources/VoiceOverlayView.swift` — armed/录音态由 mic 手势驱动(逻辑不变);视觉小巧化留给 item 1。

---

## Task 1: 迷你条骨架(Esc · 🎤 · ⏎ · 抓柄),语音先只做按住说话

**Files:**
- Modify: `ios/App/Sources/TerminalKeyBar.swift`(整体重构布局 + 加 voice/handle)
- Modify: `ios/App/Sources/TerminalViewController.swift`(setup 处接 voice 回调 → 复用 `voiceKeyAction`)

- [ ] **Step 1: 重构 TerminalKeyBar 为单行迷你条**

`TerminalKeyBar` 改为固定单行:左 `Esc`、中 `🎤 按住说话`(flex 撑开、绿调)、右 `⏎`、最右抓柄区。删掉 `keySpecs` 里除 esc/enter 外的键的布局(动作枚举 `TerminalKeyAction` 保留不动,供抽屉用)。新增:
```swift
// 顶部加(类成员)
var onVoiceGesture: ((_ phase: UIGestureRecognizer.State, _ translationY: CGFloat) -> Void)?
var onHandlePan: ((_ phase: UIGestureRecognizer.State, _ translationY: CGFloat) -> Void)?
private let micButton = UIButton(type: .custom)
private let handle = UIView()      // 抓柄小横条
```
布局(`layoutSubviews`)只摆 Esc / mic / Enter / handle 四块;mic 用绿色渐变背景 + "🎤 按住说话";handle 是 40×5 圆角条放左下(避开 mic)。给 mic 挂 `UILongPressGestureRecognizer(minimumPressDuration:0)` → `@objc micGesture(_:)`,把 `g.state` + `g.translation(in: self).y` 传给 `onVoiceGesture`;给 handle 挂 `UIPanGestureRecognizer` → `onHandlePan`。preferredHeight 改成单行高度(`rowHeight + vInset*2 + bottomInset`)。

- [ ] **Step 2: VC 接 mic 按住说话(先不做上滑)**

`TerminalViewController` setup(`keyBar` 创建处,约 L198)加:
```swift
kb.onVoiceGesture = { [weak self] state, ty in
    guard let self else { return }
    switch state {
    case .began: self.touchVoicePress(pressed: true)
    case .ended, .cancelled, .failed: self.touchVoicePress(pressed: false)
    default: break    // .changed(上滑)Task 3 再处理
    }
}
kb.onHandlePan = { _,_ in }   // Task 2 接抽屉
```
(`touchVoicePress` 现有,内部 `voiceKeyAction`。)

- [ ] **Step 3: build 验证**

Run 验证基线命令。Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: commit**
```bash
git add ios/App/Sources/TerminalKeyBar.swift ios/App/Sources/TerminalViewController.swift
git commit -m "item3 P1:底部键盘条重构为迷你条(Esc·🎤·⏎·抓柄),🎤按住说话"
```

- [ ] **真机待验:** 无硬件键盘进终端,底部出现迷你条;🎤 可见;按住 🎤 触发流式语音、松手出预览。

---

## Task 2: 抓柄上滑展开 3×3 抽屉

**Files:**
- Create: `ios/App/Sources/TerminalDrawer.swift`
- Modify: `ios/App/Sources/TerminalViewController.swift`(抽屉实例 + 布局 + onHandlePan 驱动 + 显隐联动)

- [ ] **Step 1: 写 TerminalDrawer**

新文件,VC 管理的覆盖层(加到 `view`,默认 isHidden):
```swift
import UIKit

final class TerminalDrawer: UIView {
    var onAction: ((TerminalKeyAction) -> Void)?
    var onDismiss: (() -> Void)?
    private let panel = UIView()          // 底部上拉面板
    private let dim = UIView()            // 点击收起的半透明遮罩
    private let grab = UIView()
    private var panelHeight: CGFloat = 0

    // 3×3 键序(对齐 mock v8):Paste/DelWord/Break · Mode/↑/CtrlB · ←/↓/→
    private static let grid: [(String, String, TerminalKeyAction, Bool)] = [
        ("Paste","", .paste,false), ("⌫","Del Word", .delWord,false), ("^C","Break", .ctrlC,true),
        ("⇧⇥","Mode", .shiftTab,false), ("↑","", .up,true /*arrow*/), ("^B","Ctrl-B", .ctrlB,false),
        ("←","", .left,true), ("↓","", .down,true), ("→","", .right,true),
    ]
    // 上面第 4 个 bool:Break 用红、arrow 用蓝——实现时按 action 是否方向键 / 是否 ctrlC 分别上色(别只靠 bool)。

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        dim.backgroundColor = UIColor(white: 0, alpha: 0.001) // 命中测试用,几乎透明
        addSubview(dim); addSubview(panel)
        panel.backgroundColor = UIColor(red:0.06,green:0.08,blue:0.11,alpha:0.99)
        panel.layer.cornerRadius = 16; panel.layer.maskedCorners = [.layerMinXMinYCorner,.layerMaxXMinYCorner]
        // grab + 9 个 UIButton(grid 顺序),3 列网格;方向键蓝调、Break 红调;Del Word 可长按连删(复用 repeat 逻辑或简单 tap)
        // 每个按钮 addAction → onAction?(action)
        let tapDim = UITapGestureRecognizer(target:self,action:#selector(dismissTap))
        dim.addGestureRecognizer(tapDim)
        let pan = UIPanGestureRecognizer(target:self,action:#selector(panClose(_:)))
        panel.addGestureRecognizer(pan)   // 面板内下滑收起
    }
    required init?(coder:NSCoder){fatalError()}

    func present(in container: CGRect) { /* 设 frame=container;算 panelHeight;panel 从底部 translateY=panelHeight 起;isHidden=false;animate 到 0 */ }
    func dismiss() { /* animate panel 下移出去 → isHidden=true → onDismiss */ }
    /// 抓柄拖动驱动(progress 0→1):跟手移动 panel;由 VC 的 onHandlePan 调
    func drag(toProgress p: CGFloat) { /* panel.transform = translateY(panelHeight*(1-clamp(p))) */ }
    func settle(open: Bool) { open ? present-final : dismiss() }

    @objc private func dismissTap(){ dismiss() }
    @objc private func panClose(_ g:UIPanGestureRecognizer){ /* 下滑 translation→progress;ended 时按阈值 settle */ }
}
```
(实现时:9 个按钮用 3 列 UIStackView 或 frame 网格;高度 = grab + 3×44 + gaps + 安全区;`present` 时面板贴底、含 `safeAreaInsets.bottom`。)

- [ ] **Step 2: VC 接抽屉**

`TerminalViewController`:加 `private let terminalDrawer = TerminalDrawer(frame: .zero)`;setup 里 `view.addSubview(terminalDrawer)` + `terminalDrawer.onAction = { [weak self] a in self?.handleKeyBarAction(a) }` + `terminalDrawer.onDismiss = { }`。`onHandlePan` 改成:
```swift
kb.onHandlePan = { [weak self] state, ty in
    guard let self else { return }
    self.terminalDrawer.frame = self.view.bounds
    switch state {
    case .began: self.terminalDrawer.present(in: self.view.bounds) // 起手即就位(progress 0)
    case .changed: self.terminalDrawer.drag(toProgress: -ty / 220) // 上滑 ty 为负 → 正 progress
    case .ended, .cancelled, .failed: self.terminalDrawer.settle(open: -ty > 80)
    default: break
    }
}
```
抽屉显隐随终端:在所有设 `term.isHidden = true` 的站点补 `terminalDrawer.dismiss()`(showListView / cancelTerminalSlide hideAfter / showListViewSlidingOut)。

- [ ] **Step 3: build 验证** — 基线命令,Expected `BUILD SUCCEEDED`。

- [ ] **Step 4: commit**
```bash
git add ios/App/Sources/TerminalDrawer.swift ios/App/Sources/TerminalViewController.swift
git commit -m "item3 P2:抓柄上滑展开 3×3 抽屉(剩余 9 键,方向键倒 T 沉底)"
```

- [ ] **真机待验:** 抓柄上滑出抽屉;9 键功能正常(Paste/Del Word/Ctrl-B/Mode/Break/方向键);下滑或点外部收起;不与右缘拨轮/右滑回列表打架。

---

## Task 3: 🎤 按住上滑 → 锁长录音(armed 迁移到 mic 手势)

**Files:**
- Modify: `ios/App/Sources/TerminalViewController.swift`(把 `handleTermVoicePress` 的 `.changed` armed 逻辑搬进 `onVoiceGesture` 的 `.changed`)

- [ ] **Step 1: 在 onVoiceGesture 实现 armed/上滑**

把现有 `handleTermVoicePress` 里 `.changed` 的 armed 判定(`voice.armedLock` / `voiceArmed` / `voiceOverlay.showArmed` / 滞回)逻辑迁到 `onVoiceGesture` 的 `.changed`,但**阈值改用手势 translationY**(更高门槛,如上滑 > 90pt 才 armed,带「↑ 松手转录音」预告);`.ended` 时 `if voiceArmed { lockVoiceToRecording() } else { touchVoicePress(pressed:false) }`。流式态 overlay 仍 `voiceOverlay.show(...)`,armed 时 `voiceOverlay.showArmed(...)`。

```swift
case .changed:
    guard self.voice.currentState == .streaming else { return }
    let armed = (-ty) > 90               // 上滑超过门槛
    if armed != self.voiceArmed {
        self.voiceArmed = armed
        armed ? self.voiceOverlay.showArmed(text: self.voice.currentPartial ?? "")
              : self.voiceOverlay.show(status: "🎤 聆听中…", text: self.voice.currentPartial ?? "")
        if armed { self.keyHaptic.impactOccurred() }
    }
case .ended, .cancelled, .failed:
    if self.voiceArmed { self.voiceArmed = false; self.lockVoiceToRecording() }
    else { self.touchVoicePress(pressed: false) }
```
(`.began` 仍 `touchVoicePress(pressed:true)` + `voiceArmed=false`。)

- [ ] **Step 2: build 验证** — 基线命令。

- [ ] **Step 3: commit**
```bash
git add ios/App/Sources/TerminalViewController.swift
git commit -m "item3 P3:🎤 按住上滑转长录音(门槛提高+预告),复用 lockVoiceToRecording"
```

- [ ] **真机待验:** 按住 🎤 上滑过门槛出「↑松手转录音」→ 松手进录音态(🔴计时 + 取消/停止);滑回松手 = 普通语音;门槛不易误触。

---

## Task 4: 删隐形语音热区 + 收尾

**Files:**
- Modify: `ios/App/Sources/TerminalViewController.swift`

- [ ] **Step 1: 移除终端正文上的语音热区**

删 `terminalTouchZone` 的 `.voice` 分支(只保留 `.none`,或整个移除该函数若无其它引用);删 `handleTermVoicePress` 在 `term` 上的 `voicePress` 手势注册 + 该函数(语音已全走 mic);`gestureRecognizerShouldBegin` 里 `termVoicePress` 分支删除;`terminalBottomVoiceZoneHeight` 若仅 voiceOverlay.reservedBottomInset 用,可保留为 0 或改用迷你条高度。确认 `voiceOverlay`/`lockVoiceToRecording`/`finishVoiceRecording`/`cancelVoiceRecording` 仍被 mic 路径正确驱动。

- [ ] **Step 2: build 验证** — 基线命令;额外 grep 确认无残留:
```bash
cd ios/App/Sources && grep -n "handleTermVoicePress\|termVoicePress\|\.voice" TerminalViewController.swift
```
Expected: 仅剩必要引用(无悬空)。

- [ ] **Step 3: commit**
```bash
git add ios/App/Sources/TerminalViewController.swift
git commit -m "item3 P4:删终端隐形语音热区(语音入口统一到迷你条 🎤)"
```

- [ ] **真机待验:** 点终端正文底部不再触发语音(只 mic 触发);F1 硬件键语音仍可用;右滑回列表、右缘拨轮、抽屉、Esc/Enter 全正常。

---

## Task 5(可选,可并入 item 1):录音态小巧条

录音态目前是 `VoiceOverlayView` 卡片(🔴计时 + 取消/停止并转写),功能完整。mock 里的「底部小巧录音条」属视觉收敛 → **建议并入 item 1 统一风格**一起做,避免重复改 `VoiceOverlayView` 两次。本项不在 item 3 必做范围;若 item 1 前用户想先要,再单列任务。

---

## Self-Review

- **Spec 覆盖:** §3.1 迷你条=Task1;§3.2 🎤按住/上滑=Task1+3;§3.3 录音态=复用现有(Task5 视觉收敛);§3.4 抽屉=Task2;§3.5 删热区=Task4。覆盖齐(录音态视觉显式延后,已注明)。
- **类型一致:** `TerminalKeyAction`(现有枚举)抽屉/迷你条共用;`onVoiceGesture`/`onHandlePan`/`onAction` 命名跨 Task 一致;`handleKeyBarAction`/`touchVoicePress`/`lockVoiceToRecording`/`voiceArmed`/`voiceOverlay` 均现有符号。
- **占位符:** TerminalDrawer 的 `present/drag/settle/panClose` 给了职责与签名 + 关键实现注释(translateY 跟手 + 阈值 settle),非「TODO」;实现时按注释补完。
- **风险:** Task1 重构 TerminalKeyBar 影响最大(它现是 inputAccessoryView,布局/高度变),build + 真机重点验;mic 长按手势跨出 accessory 的 `.changed` 跟踪行为需真机确认(架构假设)。
