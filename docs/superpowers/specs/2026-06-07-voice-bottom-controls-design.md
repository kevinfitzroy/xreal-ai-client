# 语音触发交互 + 底部控件重构(常驻条 + 抓柄抽屉)— 设计文档

> 日期:2026-06-07 · 平台:iOS(Agent Station)· 状态:待实施 · 对应 issue「item 3」
> 目标:① 语音入口可发现(新手一眼找到);② 长录音不再误触;③ 底部控件不挤占/不遮挡正文(高频常驻、低频收抽屉)。

---

## 1. 目标 / 非目标

**目标**
- 语音入口**可见可发现**:常驻一个 🎤 按钮(取代现在的隐形底部热区)。
- 长录音**不误触**:入口从隐形热区改为可见 mic + 上滑门槛提高 + 录音态醒目 UI + 结束按钮。
- 底部控件**分层**:高频(语音/Esc/Enter)常驻顺手;低频(方向键等)收进**抓柄抽屉**,平时零占用、不遮挡正文。

**非目标(YAGNI)**
- 不新增任何**新终端控制键**:抽屉只放**现有** `TerminalKeyAction`,一个不多。
- 不改 Android。
- 不在本轮做整体视觉统一(那是独立的 item 1)。

---

## 2. 现状(被替换/改造的东西)

- **触屏控制键** = `TerminalKeyBar`(`UIInputView`,无硬件键盘时挂 SwiftTerm `inputAccessoryView`)。当前一/两行铺**全部 11 个键**:`esc · paste · ←↑↓→ · delWord · ctrlB · shiftTab(Mode) · ctrlC(Break) · enter`(见 `TerminalKeyBar.keySpecs` / `TerminalKeyAction`)。
- **语音入口** = 终端**底部 2/15 隐形长按热区**(`terminalTouchZone == .voice` + `handleTermVoicePress`)+ F1 硬件键。**无任何可见标识** → 找不到。
- **长录音** = 在该热区按住时**上滑过 `voiceOverlay.armZoneBottomY()` → armed → 松手 `lockVoiceToRecording()`**。门槛低 → 易误触。录音态 HUD(`recordingHUD` / `VoiceOverlayView` recordingControls:取消/停止并转写)已存在。

---

## 3. 目标设计

### 3.1 常驻迷你条(always-on,docked 底部,占一点高度、不遮挡正文)
- 三键:**`Esc` · `🎤 按住说话` · `⏎ Enter`**(`Esc`/`Enter` = 现有 `TerminalKeyAction`;`🎤` = 新增语音键)。
- 🎤 为主键:flex 撑开 + 绿调,一眼可见;Esc/Enter 等宽次级;触摸目标 ≥44。
- 条顶**左下一个抓柄**(iOS sheet 同款短横条):拉住**上滑 → 展开抽屉**。
- 无硬件键盘时显示(同现 `TerminalKeyBar` 显隐规则);有硬件键盘则隐藏。

### 3.2 🎤 语音键(取代隐形热区)
- **按住** → 语音输入:`voiceKeyAction(pressed:true/false)`(复用现有 voiceDown/voiceUp 流式 ASR → 预览 → Enter 注入)。
- **按住 + 上滑**(过**比原来更高**的门槛,带「↑ 松手转长录音」预告)→ 松手 `lockVoiceToRecording()` 锁定长录音;滑回去松手 = 取消升级(回普通语音)。
- mic 上挂极小「↑录音」提示,告知可上滑。

### 3.3 长录音态 UI(小巧)
- 锁定后:迷你条**就地变成小巧录音条**(同尺寸,非大卡片):`● 计时 · 录音中 ······ 取消 | 结束`。
- 复用现有录音管线(`lockVoiceToRecording` → 分段转写 → 委托当前 subproject);把现有 recordingControls/HUD 收敛成这条小巧样式。
- 误进也一眼看到 + 随手「结束/取消」。

### 3.4 抓柄抽屉(低频键,默认收起、零占用)
- **3×3 紧凑网格,9 键零空位**,方向键倒 T 沉底:
  ```
  Paste     Del Word   ^C Break
  ⇧⇥ Mode   ↑          ^B Ctrl-B
  ←         ↓          →
  ```
  - 方向键(`up/down/left/right`)蓝调微弱区分,倒 T 形状可读,沉到最底(最贴拇指)。
  - `^C Break`(`ctrlC`)右上角、红调(最显眼,"停"直觉位);`Paste`/`Del Word`(`delWord`,可长按连删)顶排;`Mode`(`shiftTab`)/`Ctrl-B`(`ctrlB`)中排夹 ↑。
- 抽屉顶同款抓柄:**下滑收起**(或点抽屉外灰区收起)。
- **抽屉内只此 9 个现有键,不新增**。

### 3.5 删除
- 终端**底部 2/15 隐形语音热区**(`terminalTouchZone` 的 `.voice` 分支 + 在终端正文上的 `handleTermVoicePress` 绑定;改由 🎤 按钮接管)。
- 旧 `TerminalKeyBar` 的"全部键铺满一/两行"布局(重构为迷你条 + 抽屉)。
- 保留:**F1 硬件键 = 语音**、右滑 = 回列表、右缘拨轮滚动(item 2 已定)。

---

## 4. 实现要点 / 架构

- **推荐**:把底部控件改为 **VC 管理的组件**(不再用 `inputAccessoryView`),因为:
  - 终端本就抑制软键盘(`inputView` 0 高),无软键盘可避让,docked 在底部安全区即可(已有 `termBaseFrame` 安全区适配)。
  - 🎤 的「按住 + 上滑(进终端区域)」+ 抽屉「抓柄上滑」都需要**完整手势控制**;`inputAccessoryView` 在键盘窗口,跨窗口手势难做。
  - 组件:`TerminalControlBar`(迷你条,含 🎤 手势 + 抓柄)+ `TerminalDrawer`(3×3 拉出面板)。`termBaseFrame` 预留迷你条高度。
- **复用**:`voiceKeyAction` / `lockVoiceToRecording` / 录音管线 / `VoiceOverlayView`(流式预览 + 录音态)/ `TerminalKeyAction` 全部动作(抽屉/迷你条按钮回调走现有 `handleKeyBarAction`,Esc/Enter/方向键/Ctrl-B/Ctrl-C/Mode/Paste/Del Word 行为不变)。
- **手势仲裁**:🎤 按住+上滑(录音)vs 抓柄轻滑(展开抽屉)起点分开(抓柄在左下、mic 在中);录音需先按住 mic,抓柄是直接滑 → 不冲突。与右缘拨轮(右边缘)、右滑回列表也不冲突。
- **显隐**:迷你条/抽屉仅终端态显示,随 `term` 显隐联动(同现有 `scrollRail.isHidden` 那批站点)。

---

## 5. 真机才能验(需你协助)

1. 🎤 按住说话 / 上滑转录音的**门槛手感**(多高算"明显上滑")。
2. 录音态小巧条 + 结束/取消是否清楚好按。
3. 抓柄上滑展开 / 下滑收起的**手感与动画**;与 mic 上滑、右缘拨轮、右滑回列表**不打架**。
4. 抽屉 3×3 在不同 iPhone 宽度下键大小/间距是否舒适(触摸 ≥44)。
5. 无障碍/眼镜下可见性。

---

## 6. 涉及文件

- 重构:`ios/App/Sources/TerminalKeyBar.swift` → 迷你条 + 抽屉(或拆成 `TerminalControlBar` + `TerminalDrawer`)。
- 改:`ios/App/Sources/TerminalViewController.swift`(语音入口从热区改 🎤;删 `.voice` 触摸分区;迷你条/抽屉接入 + 显隐 + 手势仲裁 + `termBaseFrame` 预留高度)。
- 可能改:`ios/App/Sources/VoiceOverlayView.swift`(录音态收敛成小巧条;armed 预告/门槛)。
- 新增组件 `.swift` 落 `App/Sources/`,XcodeGen 自动纳入。

---

## 7. 验收标准

- 终端态底部常驻可见 `Esc · 🎤按住说话 · ⏎` + 抓柄;🎤 一眼可见(可发现性达成)。
- 🎤 按住说话→注入;按住上滑→锁长录音(门槛明显、有预告、可取消);录音态小巧条 + 结束/取消清楚。
- 抓柄上滑展开 3×3 抽屉(方向键倒 T 沉底、Break 右上、9 键全为现有键),下滑收起;平时不占不挡正文。
- 隐形语音热区移除;F1/右滑/右缘拨轮不受影响。
