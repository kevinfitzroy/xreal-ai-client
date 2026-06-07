# 终端拨轮滚动(Terminal Scroll Wheel)— 设计文档

> 日期:2026-06-07 · 平台:iOS(Agent Station)· 状态:待实施
> 目标:把现在"点击半屏 → tmux 翻半页"的离散卡顿滚动,换成屏幕右缘一个**无极丝滑的拨轮**。

---

## 1. 目标 / 非目标

**目标**
- 终端滚动从"一格一格跳 + 走 SSH"变成**跟手、连续、零延迟**的拨轮交互。
- 拨轮像 **iOS 选时间的滚轮**:可拨、有惯性、逐格触觉反馈,精致。
- 平时**不占视觉**(透明),需要时才显形,不挡正文。
- 既能丝滑滚"最近内容",也能(在 tmux 会话里)接力滚到更早的历史。

**非目标(YAGNI)**
- 不做侧边滚动条 / 进度条 / 位置指示(用户明确不要)。
- 不做横向滚动、不做选择复制(终端选择手势此前已禁用,保持)。
- 不改 Android 端(本次仅 iOS;若手感成立,后续再考虑对齐 SPEC)。

---

## 2. 现状(被替换的东西)

代码全在 `ios/App/Sources/TerminalViewController.swift`,终端内核是 `TerminalHostView`(SwiftTerm `TerminalView` 子类)。

当前滚动:
- `handleTermPageTap`(~L1531):点终端**上半屏**=翻页上、**中段**=翻页下。
- `termPage(up:)`(~L1544):发 `shiftUpBytes` / `shiftDownBytes`(Shift+↑/↓)给 PTY → 远端 tmux 进 copy-mode 滚**半页**,并置 `tmuxModeLikely = true`。
- `terminalTouchZone` + `TerminalTouchZone{pageUp,pageDown,voice,none}`(~L1634):按 y 把终端核心区切片。
- `showPageCue`(~L1654):翻页时的箭头提示。
- `tmuxModeLikely` 状态机 + `startCopyModePoll`/`pollPaneInModeOnce`:跟踪是否仍在 copy-mode(驱动语音警告 + ESC 安全态)。

**为什么卡**:每滚一下都是离散半页 + 一次 SSH 往返;还把用户锁进 copy-mode(期间不能语音)。

保留不动的相邻交互:
- `handleTermVoicePress`(底部 2/15 语音热区,hold-to-talk)。
- `handleTermReturnPan`(横向右滑 → 回列表)。

---

## 3. 关键技术事实(决定方案形状)

SwiftTerm `TerminalView`(`AppleTerminalView.swift`)已有现成 API:
- `scrollUp(lines:)` / `scrollDown(lines:)`:对**本地缓冲**逐行移 `yDisp`,纯客户端、零延迟。
- `scrollPosition: Double`:`0`=顶(最旧)、`1`=底(最新)。
- `canScroll: Bool`:**alternate screen 缓冲时为 false**(全屏 TUI 如 vim/less 没有可滚的本地缓冲)。
- `changeScrollback(_:)`:运行时调本地缓冲行数。
- delegate `scrolled(source:position:)`:滚动位置变化回调。

推论 —— "混合"实际是**三段**,拨轮按情况自动接力:

```
canScroll==true(主缓冲)
  └─ 本地逐行滚(丝滑) ──滚到顶(pos==0)还继续拨上──▶ tmux copy-mode 深历史(SSH,长尾,不强求丝滑)
canScroll==false(全屏 TUI)
  └─ 没有本地缓冲 ──────────────────────────────────▶ 直接走 tmux 路径(等同旧 Shift+↑/↓)
```

---

## 4. 组件设计

按"小而单一职责"拆两块:

### 4.1 `TerminalScrollRail: UIView`(新增)
**职责**:right-edge 的隐形触摸区 + 显形视觉 + 拨动手势 + 惯性 + 逐格触觉。**对 tmux 一无所知**,只产出"滚了多少行"。

- **布局**:贴 `term` 右缘,纵向铺满终端核心高度(避开底部语音热区);
  - **隐形触摸区宽 ~42pt**(好按、不误触)——比可见条宽得多。
  - **可见竖条**:很窄(~5pt),圆角,纵向渐隐渐变;`opacity:0` 常态,touch 时淡入。
  - **柔光**:一团 radial glow 跟手指 y,touch 态可见;松手淡出。
- **手势**:自带 `UIPanGestureRecognizer`(`touch-action:none` 等价:`cancelsTouchesInView`,吃掉落在条上的触摸,不下传给 term/return-pan/voice)。
  - `.began`:显形 + 柔光定位;记起点。
  - `.changed`:`dy`(自上次回调位移)→ 累积行数 `acc += -dy / lineHeight`;取整部分调 delegate `rail(_:scrollByLines:)`,余数留下次(连续跟手)。**方向 = 内容跟手指**:手指下移 → 看更早历史。每跨过 1 行 → `UISelectionFeedbackGenerator.selectionChanged()`(逐格"咔哒")。
  - `.ended`:按末速度起 `CADisplayLink` **惯性**(每帧 `v *= friction`,默认 ~0.94;`|v|` 够小或 delegate 报"到边"则停);逐行 tick 继续;再次 touch 打断。
- **可调参数**(集中常量,真机调):`hitWidth=42`、`visWidth=5`、增益 `gain`、`friction`、tick 节流阈值。
- **触觉**:`UISelectionFeedbackGenerator`(picker 同款),`prepare()` 预热;高速时按阈值节流,避免过密发糊。

### 4.2 VC 侧消费(`TerminalViewController` 扩展)
**职责**:把 rail 的"滚 N 行"翻译成 SwiftTerm 滚动 + 触顶接力 tmux + 滚动锁 + 新消息提示。

- 实现 `rail(_:scrollByLines: Int)`:
  - 若 `term.canScroll`:
    - 上滚(看历史)且 `term.scrollPosition <= 0`(已到本地顶)→ 进入 **deep-history 接力**(见 4.3)。
    - 否则 `term.scrollUp/scrollDown(lines:)`。
  - 若 `!term.canScroll`(全屏 TUI):直接走 deep-history 接力(等同旧 Shift 行为)。
- 维护 `isPinned`(= 用户停在非底部),驱动滚动锁与新消息提示(见 4.4)。

### 4.3 触顶接力 tmux 深历史(复用现有机制)
- 触发上滚接力时:**一次轻震**(`keyHaptic`)+ 一闪而过的小提示 "历史模式 · Esc 退"(非常驻);发 `shiftUpBytes` 进 copy-mode 滚半页,置 `tmuxModeLikely=true`,启 `startCopyModePoll`。
- 继续上拨:按 rail 行数**限速**(每 SSH 往返一拍,远不及本地丝滑,这是历史长尾,可接受)发更多 Shift+↑。
- 下拨退出:发 `shiftDownBytes` 翻回;到底由现有轮询/逻辑退出 copy-mode,`tmuxModeLikely=false`,回到本地丝滑段。
- **纯 SSH(非 tmux)project**:本地到顶即尽头,不接力。
- 完全复用 `tmuxModeLikely` + copy-mode 轮询 + 语音警告,不新起状态机。

### 4.4 滚动锁 + 底部新消息提示(用户点 5)
- 用户滚离底部(`scrollPosition < 1`)时 `isPinned=true`:新输出**不把视图弹到底**。
  - 需在 `feed` 后保持 `yDisp`(若 SwiftTerm 默认自动跟随到底,则在 feed 后补回原 `yDisp`)。**此行为真机验,见 §6。**
- 底部中央浮一个 **`newMessagePill`**(`UIView`/`UIButton`):文案 "▼ 有新消息"(可带计数)。
  - 仅 `isPinned && 有新输出` 时显示;点击 → 平滑滚到底(`scroll(toPosition:1)`)+ `isPinned=false` + 隐藏。
  - 用户手动滚回到底 → 自动 `isPinned=false` + 隐藏 + 恢复跟随。

---

## 5. 删除 / 修改清单

- **删**:`handleTermPageTap`、`showPageCue`、`TerminalTouchZone` 的 `pageUp/pageDown`(及 `terminalTouchZone` 里对应分支、`pageSplitFraction`/`pageDownEndFraction`、`termPageTap` gesture 注册)。`terminalTouchZone` 仅保留 `voice` 判定。
- **保留并复用**:`termPage(up:)` 的发包逻辑(被 4.3 接力调用)、`tmuxModeLikely` 全套、`handleTermVoicePress`、`handleTermReturnPan`。
- **改**:`gestureRecognizerShouldBegin` —— rail 的 pan 在其触摸区内优先;`handleTermReturnPan`(右滑回列表)起点落在 rail 区时**不 begin**(rail 吃掉),避免右缘竖向拨动被误判成右滑。

---

## 6. 真机才能验(我做不了,需你协助)

1. **方向**:下拉=看历史 是否符合直觉(可一键反向)。
2. **惯性手感**:`friction`/`gain` 太滑或太黏。
3. **触觉**:逐行 `selectionChanged` 的疏密;高速是否需要更强节流;是否换 `impact(.light)`。
4. **滚动锁**:SwiftTerm 在 `feed` 时是否会把滚上去的用户**自动弹到底**;若会 → 落地"feed 后补回 yDisp"。
5. **接力限速**:copy-mode 半页节奏(每拍间隔)。
6. **AR 眼镜可视性**:透明/显形对比度、可见条亮度在眼镜下是否够。

---

## 7. 涉及文件

- 新增:`ios/App/Sources/TerminalScrollRail.swift`
- 改:`ios/App/Sources/TerminalViewController.swift`(consume + 删旧翻页 + 手势仲裁 + 新消息药丸)
- 可能微调:`ios/App/Sources/TerminalHostView.swift`(若需暴露/确认 `canScroll`、scrollback 大小)
- 项目生成:`TerminalScrollRail.swift` 落在 `App/Sources/`,XcodeGen `sources: App/Sources` 自动纳入,`xcodegen generate` 后即编译(无需改 `project.yml`)。

---

## 8. 验收标准

- 主缓冲下拨轮连续丝滑滚动,无 SSH 延迟;松手有惯性。
- 平时拨轮不可见、不挡正文;触摸显形。
- 逐行触觉反馈(真机)。
- 滚到本地顶继续上拨,在 tmux 会话能接力看更早历史;非 tmux 到顶即停。
- 滚上去看历史时新输出不弹底,底部提示可一键跳回最新。
- 旧的点击翻页彻底移除,不再误触;语音热区与右滑回列表不受影响。
