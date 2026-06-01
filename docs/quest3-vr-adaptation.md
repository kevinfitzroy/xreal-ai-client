# Quest 3 适配调研 —— 把"agent 集群指挥台"空间化

> **状态**:调研(2026-05-31)。无 Quest 3 真机,本文是**方案 + 风险地图**,不是已验结论。
> **证据分三层**,文中逐条标注:
> - 🟢 **已确认**:Meta 官方文档 / 已知 Android 事实(见文末 Sources)
> - 🟡 **需真机原型验**:架构上成立但有平台坑,必须 tracer bullet 验
> - 🔴 **需用户确认**:卡在硬件 / 方向,我做不了
>
> 调研结论先行:**走 Meta Spatial SDK,建一个沉浸式 Kotlin app,把现有 WebView 终端栈做成 N 个空间 panel**。不走系统 2D 多任务(窗口上限 + 同 app 不能多实例),不走 Unity(丢整个栈),不走 WebXR(丢 sshj、违反零服务端)。

---

## 1. 为什么"多开"是 VR 的命门 —— 而它正好是本项目的 DNA

用户的判断对:VR 头显如果不能同时开很多窗口,相对手机/眼镜就没有竞争力。但对**这个**项目,多开不是为多开而多开——它正好把产品本质空间化了。

本项目的产品定位(memory `product-vision`)是 **AI agent 集群指挥台**,不是单纯 SSH client。当前在 Beam Pro 上是"一次看一个终端、来回切"。搬到 Quest 3,自然形态变成:

> **一面墙的 agent 终端**。jump-edge / private-worker 两台 host 上每个 Maestro session 各占一个 panel,环绕用户铺开。一眼扫全队状态(working / waiting / disconnected),gaze/手柄选中某一个 → focus 进去用键盘+语音驱动它,驱动完抬头看下一个。

这就是"为什么 VR 值得做"的叙事,而且它**直接解掉本方案最大的技术矛盾**(见 §5):

- 绝大多数 panel 是 **glanceable 监控**——只读、低刷新,甚至只渲染 `tmux capture-pane` 的快照(复用已有的 status hooks,见 CLAUDE.md §6)。这些用**廉价 textured-mesh** 渲染就够。
- 只有**当前 focused 的那一个**需要全保真:交互式 WebGL 终端 + compositor layer(原生分辨率,文字清晰)。

产品形态和 GPU 预算在这里收敛。**这是本方案的中心论点**,不是脚注。

---

## 2. 平台事实(🟢 已确认)

| 事实 | 内容 | 对本项目的意义 |
|---|---|---|
| Quest 3 OS | **Meta Horizon OS = AOSP fork**。app 用 Android Studio + Kotlin + Jetpack 建 | 现有 `android/` 模块的语言/工具链**直接适用** |
| Target SDK | 2026-03-01 起新 app 须 target **Android 14(API 34)**,minSdk 可 API 32/29;另叠一层 `horizonos:uses-horizonos-sdk`(minSdk 201 / target 203) | 现有 app **已 target API 34**,Android 层基本就绪;Quest 增量 = 加 Spatial SDK 依赖 + horizonos manifest |
| Meta Spatial SDK | 用 Kotlin/Android 建 Horizon OS 沉浸式 app,ECS 架构,把 **2D panel 放进 3D 空间** | **这是复用现有栈的那条路**(不是 Unity 重写) |
| Panel 内容源 | `ViewPanelRegistration`(任意 **View**)/ `ActivityPanelRegistration`(托管 **Activity**)/ LayoutXML / Intent / Compose。注册一次、运行时 **spawn/destroy 多个**、`Pose` 定位 | **WebView 是 View** → 终端 UI 可做成 panel;运行时动态增删 = 开/关终端 |
| 单 panel 渲染 | 默认 textured-mesh(文字糊);开 **compositor layer**(`layerConfig = LayerConfig()`)→ 原生分辨率、文字清晰。单 panel ≤ **2064×2208 px**(内存约束) | 终端是密集小字,focused panel **必须开 compositor layer**;分辨率上限 × N 是真实预算 |
| 系统 2D 多任务 | 普通 2D app 最多 **~6 窗口**(3 docked + 3 浮动);"Seamless Multitasking" 在沉浸 app 旁只允许跑 1~3 个 2D app | **不够**,且不支持同 app 多实例 → 不能靠系统堆终端,必须自建沉浸式 app 管 N panel |
| 输入外设 | Quest 3 支持**蓝牙键盘**(Tracked Keyboard / Generic Keyboard Tracker);手柄 + 手势 + gaze | 8BitDo 蓝牙键可配对;物理键有望仍走 panel 的 `dispatchKeyEvent`(🟡 待验路由) |
| 麦克风 | Horizon OS 是 Android,`AudioRecord` + `RECORD_AUDIO` 可用;沉浸 app 自身即焦点 | 语音链路(`AudioRecorder`→豆包 ASR)可搬;**且不再需要前台 Service**(沉浸 app 本就在前台) |

---

## 3. 备选方案 & 为什么否决

| 方案 | 能多开? | 否决理由 |
|---|---|---|
| **系统 2D 多任务**(现有 app 原样侧载) | ❌ 最多 ~6 窗口,同 app 不能多实例 | 达不到"开很多";窗口由系统管、不可编程控位 |
| **Unity / Unreal 原生 XR** | ✅ | 丢掉整个 sshj + WebView/xterm.js + VoiceDaemon 栈,等于重写;违背单 app 闭环的既有投资 |
| **WebXR(Quest 浏览器)** | ✅ panel | 浏览器**做不了裸 TCP SSH** → 必须加 websocket 代理 = **违反零服务端增量**(CLAUDE.md §5 头条) |
| **✅ Meta Spatial SDK 沉浸式 app** | ✅ 自管 N panel | 保留 sshj(原生 Kotlin)+ WebView/xterm.js(做 panel)+ Voice;单 APK 单进程;窗口可编程定位 |

---

## 4. 推荐架构

```
┌─ 一个沉浸式 Spatial SDK APK(单进程)──────────────────────────┐
│                                                                │
│  Spatial Scene(ECS)                                          │
│   ├─ Launcher panel ── 项目列表(现 MainActivity 的列表 UI)   │
│   ├─ Terminal panel #1 ─ WebView(index.html/xterm.js)──┐     │
│   ├─ Terminal panel #2 ─ WebView ──────────────────────┤     │
│   ├─ ...                                                 │     │
│   └─ Status panel #N ── 只读 capture-pane 快照(glanceable)│   │
│                                                          │     │
│  焦点管理器:gaze/手柄选中 → focused panel                │     │
│   └─ 键盘 dispatchKeyEvent + 语音 ASR 都注入 focused      │     │
│                                                          ▼     │
│  SSH 多路复用层(sshj):每 host 1 条连接 + N 个 PTY channel    │
│   └─ jump-edge 直连 / private-worker 经 jump-edge ProxyJump(SshJump,一次跳板复用)    │
│                                                                │
│  Voice(AudioRecord→豆包 ASR)— 无需前台 Service               │
└────────────────────────────────────────────────────────────────┘
            │ Raw SSH(零服务端增量,内网经 ProxyJump)
            ▼   jump-edge / private-worker,各跑 Maestro + tmux
```

### 4.1 代码复用矩阵

| 现有模块 | Quest 处置 | 说明 |
|---|---|---|
| `SshConnection` / `SshJump` / `PtyChannel` / `TofuKnownHosts` | **基本搬,改连接复用** | 见 §6.2:1 host 1 连接 + N channel |
| `index.html` + xterm.js + WebGL + overlay(`assets/`) | **原样搬进 panel** | 跟 iOS POC 同款"WKWebView 原样跑 index.html"思路;每 panel 一个 WebView |
| `TerminalBridge`(Base64 双向桥)| **搬** | WebView↔Kotlin 桥不变 |
| `VoiceDaemon` / `AudioRecorder` / `VolcEngineAsr` / `Hotwords` | **搬,去掉前台 Service** | 沉浸 app 即焦点;ASR 文本注入 focused panel 的 PTY |
| `StatusPoller` / `ManifestFetcher` / `AgentModels`(含 `via`)| **搬** | glanceable status panel 直接吃这套 |
| `MainActivity` 的列表 UI | **重做成 launcher panel** | 列表逻辑(findProject/导航)留,宿主从 Activity 换成 panel |
| `XrealApp` / `AppLog` / `SettingsStore` / `Crypto` | **搬** | 可观测性 + 配置存储不变 |
| 物理键路由(`dispatchKeyEvent` F1/F2)| **搬,改成"路由到 focused panel"** | 多窗口新问题,见 §6.1 |
| **新建** | Spatial Scene / panel registration / 焦点管理器 / 空间布局持久化 | 这是唯一真正的新代码量 |

> 净评估:**SSH / 终端渲染 / 语音 / 状态四大块直接复用**,新代码集中在"空间外壳 + 多窗口管理"。比 iOS 那次移植**复用率更高**(iOS 要重写 SSH=Citadel、Voice=AVAudioEngine;Quest 同为 Android,这些都不用换)。

---

## 5. compositor 预算 × N —— 用产品形态解,不是用蛮力

终端是密集小字,focused 那个**必须** compositor layer 才清晰(否则 textured-mesh 糊)。但 compositor layer 在 Quest 上数量有上限(OpenXR 合成层,历史经验是个位~十几量级,**确切值必须真机 benchmark,别照搬任何数字**)。给 20 个终端每个都配一层 = 撑不住。

解法就是 §1 的产品形态:

| panel 角色 | 数量 | 渲染 | 成本 |
|---|---|---|---|
| **focused 交互终端** | 1(偶尔 2~3) | WebGL + compositor layer + 原生分辨率 | 高,但只此一个 |
| **glanceable 监控** | 多(一墙) | textured-mesh,低刷新;内容可只是 `capture-pane` 快照而非活 WebGL | 低 |

切 focus = 把目标 panel 升级成 compositor layer + 启活交互,旧 focus 降级回快照。**"指挥台"本来就是一个主驾驶 + 一墙监视器,不是 20 个同时全速跑。**

---

## 6. 多开带来的两个新设计问题(单终端 app 里不存在)

这两个是"多开"的核心,不是边角。

### 6.1 焦点 / 输入路由(🟡)

单终端时键盘/语音无歧义。N 个 panel 时必须答:**这次按键/这句语音进哪个终端?**

- 选中:gaze 或手柄射线选中一个 panel → 标记 focused。
- 键盘:物理键事件路由到 focused panel 的 WebView(`dispatchKeyEvent` 仍是同 app 内事件,不需 Accessibility/IME —— CLAUDE.md §5 约束保持)。
- 语音:F1 hold-to-talk → ASR 文本写 focused panel 对应的 PTY `outputStream`。voice overlay 仍是该 panel WebView 里的 `<div>`(零 SYSTEM_ALERT_WINDOW,约束保持)。
- 8BitDo F2(返回列表)语义在多窗口下要重定义(关当前 panel?回 launcher?)——产品决策,留给真机阶段。

### 6.2 SSH 连接复用:1 host 1 连接 + N channel(🟡)

**不要** N 个终端开 N 条 SSH 连接。SSH 协议本就在一条 TCP 传输上多路复用 channel;一台 host 开一条连接、跑 N 个 PTY session channel:

- 省 N-1 次握手 / reader 线程 / known_hosts 校验;
- ProxyJump(`SshJump` 本地端口转发)只跳一次,N 个内网 PTY 复用同一条跳板隧道 —— private-worker 经 jump-edge 多跳的开销摊薄到一次。

⚠️ **约束需重新设计**:memory `input-path-constraints` 锁定"SSH 写入必须后台单线程"(主线程写永久损坏 sshj 缓冲)。单连接单 channel 时一个 writer 线程够;**N channel 下要每 channel 串行化写**(单 writer 线程 + 路由到目标 channel 的队列,或每 channel 一个专用写线程)。这条不能含糊,改之前先想清线程模型。

---

## 7. 关键风险 / 必须真机原型验(🟡)

按"会不会让方案翻车"排序。**第一颗 tracer bullet 必须先于任何架构承诺**,照搬 repo 里 iOS 的 POC 先例(先一个 WebView 终端 panel 跑通,再谈 N 个)。

| # | 风险 | 为什么是 gating | 怎么验 |
|---|---|---|---|
| R1 | **WebView 渲染进 panel + 触摸/键盘坐标映射** | 整个复用故事的命门。硬件加速 WebView 渲染到离屏 texture/layer 历来有坑,Meta panel 文档**没明确点 WebView**(只说"任意 View") | tracer bullet:一个 `ViewPanelRegistration` 挂 WebView 跑 index.html,验渲染清晰 + 点击/按键坐标对得上 |
| R2 | **N × WebGL 上下文的性能 / 热** | 每终端是 xterm.js + WebGL,N 个 GL context 叠 Spatial SDK 自身渲染,Quest 3 的 Adreno + thermal 下 8+ 个可能撑不住 | benchmark 帧率/温度;对策已在 §5(focused=WebGL,background=canvas/DOM 快照或降帧) |
| R3 | **compositor layer 数量上限** | 决定能同时"全保真"几个终端 | 真机 benchmark 出确切数,**别 assert** |
| R4 | 8BitDo 物理键经蓝牙在 Horizon OS 的 keycode 投递 | 跟 Beam Pro 的 `Generic.kl` 注释坑(Stage A.1)同类风险,Quest 的 keylayout 未知 | 真机抓 keycode(同 Stage A.1 方法) |
| R5 | 真机配置注入通道(无 `adb push` 沉浸式等价?Quest 支持 adb,大概率可沿用) | Valet setup 依赖 adb push key+manifest | 验 Quest adb 侧载 + `/data/local/tmp` 通道 |

---

## 8. 与 CLAUDE.md §5 七条约束的对齐(🟢 全部保持)

| 约束 | Quest 方案是否守住 |
|---|---|
| 零服务端增量(唯一例外=status hooks)| ✅ SSH 仍 sshj 直连;status panel 复用已有 `.xreal/status.json` hooks,无新服务端 |
| 单 App 闭环 | ✅ 一个沉浸式 APK 单进程,N panel + N channel + voice 全在内 —— **比现在更贴合** |
| Overlay = WebView 内 HTML | ✅ voice overlay 仍是 focused panel WebView 里的 `<div>`,零 SYSTEM_ALERT_WINDOW |
| Voice → SSH 直写 | ✅ ASR 文本写 focused panel 的 PTY `outputStream` |
| 不用 Accessibility / IME | ✅ 键盘走同 app 内 `dispatchKeyEvent` 路由到 focused panel |
| agent 用 tmux | ✅ 不变;"一墙 glanceable 监控"更依赖 `capture-pane` |
| 优雅降级 | ✅ 同一套代码可同时出**扁平 2D app**(现 MainActivity)在 Quest 当单 panel 跑 → 沉浸层挂了仍能用;单 panel 崩溃彼此隔离 |

---

## 9. SPEC.md 影响(🔴 需用户确认走向)

Quest 是 **SPEC.md 的第三个实现**(Android / iOS / Quest)。但**多窗口打破了 SPEC 隐含的"一次一个终端"假设**——焦点路由、多实例、空间布局持久化,SPEC 现在都没有词汇描述。

两条路,二选一(产品决策):
1. SPEC 升一层,加 **window-manager / multi-instance / 焦点** 语义,三端共用;
2. 显式把"多窗口"划为 **Quest 平台特定**,SPEC 仍只管单终端契约。

倾向 (2) 起步(多窗口暂时只 Quest 有,过早抽象会内耗 —— 跟 memory `second-client-ios` 防内耗同理),等 iOS/Android 也要多窗口时再上提。

---

## 10. 分阶段计划(tracer bullet 优先)

| 阶段 | 内容 | 出口判据 |
|---|---|---|
| **P0 tracer** | 空 Spatial SDK app + **一个** WebView panel 跑 index.html(R1) | 真机上一个终端 panel:渲染清晰、点击/按键对位、SSH echo 闭环 |
| **P1 单终端打通** | 复用 SshConnection/Bridge/Voice,单 panel 端到端(连 jump-edge，打字+语音) | 等价现在 Beam Pro 的单终端体验,只是在 VR 里 |
| **P2 多开** | N panel + 焦点路由(§6.1)+ SSH 连接复用(§6.2)+ glanceable 状态墙(§5) | 同时开 ≥4 个终端,切焦点驱动,扫全队状态 |
| **P3 空间体验** | 布局持久化(panel 摆哪记住)、8BitDo(R4)、配置注入(R5) | 脱离 dev rig 日常可用 |

每阶段截图/录屏验过即 commit(不 push),沿用 memory `phase-build-autocommit` 节奏。

---

## 11. 头号硬 gate(🔴 需用户回答)

**整个 prototype 阶段都需要 Quest 3 真机**,而按 CLAUDE.md 我做不了设备验证(渲染清晰度、WebGL 热、物理键 keycode、adb 侧载全是真机项)。在投入写 Spatial SDK 代码前必须确认:

- **你有 Quest 3 吗?** 有没有 Quest 开发者账号(侧载需开 developer mode)?
- 优先级:这是和 iOS(另一 session 在做)并行的**第三端探索**,还是要排在 iOS 之后?

没真机的话,我能先做的**不需要设备**的部分:Spatial SDK 工程脚手架 + panel 注册骨架 + SSH 多 channel 复用层重构(纯 JVM 可单测)+ SPEC 草案 —— 但 R1(WebView-in-panel)这个命门验不了,不建议在它之前堆太多架构。

---

## Sources

- [Building with Meta Spatial SDK](https://developers.meta.com/horizon/develop/spatial-sdk/)
- [Spatial SDK overview](https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-explainer/)
- [2D panels in Spatial SDK](https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-2dpanel/) / [panel registration](https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-2dpanel-registration/) / [spawn/remove](https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-2dpanel-spawn/) / [resolution & layers](https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-2dpanel-resolution/)
- [Meta Spatial SDK Samples (GitHub)](https://github.com/meta-quest/Meta-Spatial-SDK-Samples)
- [Meta Horizon apps must target Android 14 (March 1)](https://developers.meta.com/horizon/blog/meta-quest-apps-android-14-march-1/) / [Horizon OS SDK versioning](https://developers.meta.com/horizon/documentation/android-apps/horizon-os-sdk-versioning/)
- [Getting started with Android apps on Horizon OS](https://developers.meta.com/horizon/documentation/android-apps/horizon-os-apps/)
- [Quest 多窗口多任务上限(UploadVR / Meta Help)](https://www.uploadvr.com/seamless-multitasking-experimental-quest/) / [Moving and adjusting windows](https://www.meta.com/help/quest/542427545314119/)
- [Tracked / Generic Keyboard(蓝牙键盘)](https://developers.meta.com/horizon/blog/presence-platform-interaction-sdk-and-tracked-keyboard-now-available/)
