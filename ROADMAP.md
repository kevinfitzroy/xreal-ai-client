# ROADMAP — 分级需求跟踪

> 按**优先级分层**跟踪需求,而不是按 phase。判据是:**这条断了,整体流程还能不能打通?**
> - **P0 核心**:断了 = app 不可用。**已全部打通**(Beam Pro X4100 真机日常用);焦点已移到 P1 收尾 + P2。
> - **P1 可用性**:当前未完成 P1 = **富媒体预览** + **terminal 触摸热区 / 语音 overlay 交互**。其它未完成项默认降到 P2/P3,不抢主线。
> - **P2 体验增强**:不影响主流程,可随时搁置 / 接回。**搁置的必须留接口 + 在本文件记接回清单**。
>
> 维护规则:状态变化随手改这里(✅ done / 🚧 进行中 / ⏸️ 搁置 / ⬜ 未开始)。搁置一个功能时,把它的接口点写进 §4「接回清单」。

---

## P0 — 核心流程(已全部打通)

最小端到端闭环:**开 app → 看到真实项目列表 → 键盘导航 → Enter 开真 SSH 终端 → 打字(硬件键+虚拟键盘)/语音 → BACK 回列表**。任何一环断了主流程就断。

| # | 需求 | 状态 | 备注 |
|---|---|---|---|
| P0.1 | 列表枚举真实 host/project | ✅ | 静态 seed(`StatusPoller.staticListJson`)→ `ManifestFetcher` live-fetch manifest 覆盖(见 P1.1c)→ `window.setHosts`。**这是开真终端的前提**(Enter→`findProject` 按 session 查、seed 兜底) |
| P0.2 | 列表键盘导航(方向键 + Enter) | ✅ | index.html `setFocus`/`keydown` + 虚拟键盘 `vkey`。**键盘专用 app 的命根子,任何时候都不能移除**(≠ §P2 的舰队聚合 pills) |
| P0.3 | per-project 真 SSH 终端(attach tmux,含**多跳**) | ✅ | `onOpenProject`→`SshConnection`+`tmuxAttachCommand`;channel 热切(`switchTo`/`startReaderFor`)。**多跳 SSH(ProxyJump)已落地**:`HostConfig.via` + `SshJump`(sshj 本地端口转发),OPS via TK 端到端认证(OPS 在 AWS 内网,只 TK 的 OpenVPN 可达)。 |
| P0.4 | 终端显示(xterm WebGL + 中英文 + powerline + **翻页**) | ✅ | Meslo(Latin/powerline)+ Sarasa(CJK)+ WebGL 字体就绪;远端 `tmux -u` + UTF-8 locale。**tmux 半页翻页**:Shift+↑/↓ → root 表进 copy-mode(不与 Claude Code 冲突)+ history-limit 50000(`-f conf` 注入,服务端零增量)。 |
| P0.5 | 硬件键路由(+ 虚拟键盘兜底) | ✅ | `dispatchKeyEvent` 路由 **F1=语音 / F2=返回**(Stage A.1 实测:Beam Pro 的 8BitDo F13–F24 被 `Generic.kl` 注释、到不了 app;F13/F14 + Ctrl+Alt+1/2 分支保留作兜底)。**虚拟键盘动态显隐**:8BitDo 插拔实时切(插着隐、拔了出),去掉多余 hint 说明条 |
| P0.6 | 语音 daemon 状态机(overlay show/hide + Enter 注入) | ✅ | 骨架完成,ASR 仍是 mock(真豆包见 P1.2) |
| P0.7 | BACK 返回列表 / 优雅降级 | ✅ | BACK 键 + home 键;SSH 失败回退 LocalEcho 不卡 |

> P0 当前**已全部打通并在 Beam Pro X4100 真机日常用**(双 host:TK-ALIYUN 直连 + OPS 经 TK 多跳,各跑 Maestro)。物理设备项(8BitDo F1/F2、真麦克风)已实测。
>
> **可观测性(支撑性,非 P0 闭环)**:持久化日志 + 崩溃捕获已落地 —— `AppLog` 写外存(`adb pull`,不需 run-as)+ `XrealApp` 全局未捕获异常处理器落盘崩溃。出问题先 `adb pull` 取证。

---

## iOS 原生化 + 交互(2026-06 立项,逐项推进)

> iOS 第二客户端从「WKWebView 跑共享 index.html」走向 **全面原生**。起因:WKWebView 收不到硬件键 DOM + 软键盘抑制死结(终端);后续列表也升级成标准 iPhone 体验。**做法:一项一项做,做完一项验一项**。契约仍归 SPEC,平台落点(SwiftTerm/UITableView)进 §11 矩阵。

| # | 任务 | 状态 | 说明 |
|---|---|---|---|
| iOS.1 | **终端改原生 SwiftTerm** | ✅(2026-06-01) | 替代 WKWebView+xterm,解键盘死结。键盘全原生正确(字母/Tab/Shift+Tab/方向/Ctrl/DECCKM);F1/F2 + 语音 Enter/Esc 经 swizzle 拦;软键盘抑制 inputView 0 高;tmux 翻页 conf 注入。字体按 Android 方案打包 Sarasa/Meslo,CoreText 注册;SwiftTerm 单字体优先 Sarasa |
| iOS.2 | **触屏 vkey(无硬件键盘)** | ✅ | 无 8BitDo 时终端挂原生 `TerminalKeyBar`(inputAccessoryView):返回/方向/Enter/Esc/删词/Ctrl-B/模式/Ctrl-C/🎤;横屏 1 行竖屏 2 行;键盘避让(终端缩到 vkey 上);按键震动 + 高亮 |
| iOS.3 | **tmux 触摸翻页** | ✅ | 见 P2.8(点终端上/下半 = Shift+↑/↓) |
| iOS.4 | **列表改原生(苹果设计语言)** | 🔄 进行中(已编译,待真机验) | WKWebView/index.html 退出 iOS(只留 Android)。`DeckListView`(insetGrouped UITableView + SF Symbols + 系统色状态徽章 + disclosure + 下拉刷新)+ `DeckNavController` 大标题「Deck」。点 cell 进 project、滑动滚动、物理键方向/Enter 导航 |
| iOS.5 | **列表状态栏 / 终端全屏** | ✅ | 列表态恢复标准 iOS chrome(状态栏 + nav bar 大标题);终端态沉浸全屏(隐藏状态栏 + home indicator + nav bar)。`DeckNavController` 把状态栏决定权转发给顶层 VC |
| iOS.6 | **边缘滑动手势** | 🔄 进行中(已实现并装机,待手势真机确认) | **列表页**:右侧较宽区域左滑 → 打开**最近一次打开的终端**;**终端页**:左缘或内容区明显右滑 → 回列表。terminal 跟手滑动,垂直滚动/点按翻页不抢 |
| iOS.7 | **最近终端保活(keep-warm)** | 🔄 进行中(已实现并装机,待手势真机确认) | 离开终端后 90s 内不 close tmux/SSH,保留 SwiftTerm 绘制状态;滑入前预热/缓存 vkey 高度并先摆好 offscreen frame;返回列表时临时卸掉 vkey + 用底部 cover 隔离 hide 动画,首帧不 reload table;超时真正 close |

---

## P1 — 当前高优先级

> 2026-06-01 重排:Host 接入 / manifest / ASR 等是已完成基线;session 驻留可配置、preview 文本、fleet pills、通知、多窗口、热词管理等全部降到 P2。当前 P1 只放真正影响触屏可用性的工作。

| # | 需求 | 状态 | 备注 |
|---|---|---|---|
| P1.1 | Host 接入 = 代客安装 (Valet Setup),**无 UI** | ✅ 基本完成 | **刻意不做设置 UI**。Valet agent 经 adb push key+config → staging,app 导入私有存储(`SettingsStore.importStagingIfPresent`:key 设 600、原子写、用完删 staging、legacy 回退)。引导:`docs/agent-setup-guide.md`。剩 host 录入 UI 永不做 |
| P1.1b | Maestro CLAUDE.md + manifest 契约 | ✅ 文档 | `docs/orchestrator-CLAUDE.md` 定义角色 + manifest schema(`<base>/.xreal/projects.json`,Maestro写 app 读)。base path 存 app 配置(Valet 写),不存 manifest(防循环信任) |
| P1.1c | app live-fetch manifest | ✅ 真机验证 | `ManifestFetcher` 经 `HostClient.catFile` 拉 `<basePath>/.xreal/projects.json` → `liveProjects`(findProject 按 **session** 查、seed 兜底)→ `pushHostList` 内容去重防闪烁。**刷新 = 事件驱动零空轮询**:列表首显 / back-to-list / onStart 各拉一次(`fetchExec` 单线程串行 + `fetchGen` 防乱序;拉取失败保留当前列表)。Maestro 改 manifest → 回列表即现 |
| P1.2 | 真豆包 ASR(替 mock) | ✅ 真机验证 | **真双向流式**(`bigmodel_async` WS,`VolcFrame` 二进制协议+gzip)。按住即连 WS、`AudioRecorder` 边录边吐 200ms 裸 PCM 块(非 Opus)、中间结果实时上屏、松手发负包拿 final。会话式 `Asr` seam(`open/send/finish/cancel`+回调);race 防御=generation counter + `cancelled`/`done`。creds 走 Valet `asr.json`(无 UI)。**热词**:`corpus.context` 内联,`Hotwords.BASE`(Claude Code 控制命令)所有 project 继承 + manifest per-project 合并、按 token 预算 cap。语音键收为单 🎤。`VolcFrame`/`PcmChunker` 有 JVM 单测 |
| P1.3 | **富媒体预览(图片 / HTML,host→client 推送)** | ⬜ 未开始 | 见下「§ 富媒体预览设计」。补终端表现单一:host 上 agent 调一个**协商好的 skill/脚本**(`.xreal/xreal-preview`)→ 经 **PTY 流内哨兵**(tmux-passthrough 包裹的 OSC,对用户不可见)触发 client 弹**全屏预览层**;文件**经 SSH :22 `base64` 拉取、本地 WebView 渲染**(复刻 `HostClient.catFile` 模式,**零服务端增量,不引 host web server**)。只看交互:方向键 pan/zoom、ESC/返回退层;HTML 走 **sandbox iframe** 防触达 `TerminalBridge`。跨端契约 = **SPEC §13** |
| P1.4 | **terminal 触摸热区 + 语音 overlay 点击语义** | 🔄 iOS 已实现并装机,待真机验 | 只按 terminal 核心显示区计算,有 vkey 时先排除 vkey。核心区纵向 5 份:top 2 unit = 上翻页,中间 2 unit = 下翻页,bottom 1 unit 的底部 2/3 = hold-to-talk 语音热区;翻页触发时用半透明区域 overlay 覆盖整个触发区,叠加加大加粗箭头并短暂驻留,让用户看清范围。overlay 出现后翻页自然失效,核心区只剩 3 块:overlay 卡片点击 = Enter 注入识别文本,卡片上方点击 = Esc 取消,卡片下方按压 = 重新录音。契约 = SPEC §6 |

### Project 创建模型(2026-05-29 收敛 —— Maestro agent 驱动)

层级:`Host(SSH + base path)→ Maestro Claude Code(orchestrator)→ Project(= 工作目录 + tmux session 1:1)`。

**核心理念(因语音操作)**:用户**不在 6 键上手敲名字/路径**。每个 host 的 base path 下常驻一个**Maestro Claude Code**(自身一个 tmux session,起在 base path)。用户对Maestro用语音描述诉求("帮我开个做 X 的目录"),**Maestro负责** `mkdir` 子目录、起 session、**决定名字/路径**、登记项目。

- **嵌套不固定**:层级/分组由Maestro创建的路径决定,app 只按 manifest 渲染(可选 `group` 字段表达分组);不在 app 里写死嵌套结构。
- **app ↔ Maestro的接口 = 项目清单 manifest**:`<base>/.xreal/projects.json`(human-readable:`session`/`name`/`type`/`dir`/可选 `group`)。**Maestro写,app 读**(app 进列表时 `cat` via SSH 拉取,= P1.1c)。零服务端增量 —— 写文件是 Claude Code 的日常能力,无需 daemon。**base path 不进 manifest** —— 它在 app 的 host 配置里(Valet 写),否则Maestro能改 app 去哪读自己的 manifest = 循环信任。
- **无 host 录入 UI**:第一个 SSH 连接没法语音 bootstrap,但也**不做设置 UI**;host 的 SSH 参数 + base path 由**代客安装(Valet)经 adb 配**(P1.1)。project 级全交给Maestro。
- **worktree 不是 app 概念**:若某任务要并行分支,是**Maestro自己**决定 `git worktree add` —— 只是它手里的一个工具。很多任务不碰 git,create 层面 git-agnostic(只是"一个目录")。
- **tmux session ↔ project 1:1**:`tmux new -s <proj> -c <工作目录>` 起在该目录(现有 `tmuxAttachCommand` 已是这形状)。配角终端(shell/日志/REPL)走 project 内多窗口(见 P2.5),不是第二个 agent。

---

## P2 — 体验增强(已搁置,留接口随时接回)

不影响主流程打通。这是"AI agent 集群指挥台"愿景(见 memory `product-vision`)的差异化部分,但**核心流程能跑之后再接**。

| # | 需求 | 状态 | 接口/开关 |
|---|---|---|---|
| P2.1 | 实时状态刷新(WORKING/WAITING/时长) | ✅ 已用 **hooks** 实现(2026-05-31,真机验证) | **改走事件驱动,非抓屏**:Claude Code hooks 写 `<base>/.xreal/status.json`(`{session,state,since}`),`ManifestFetcher.fetch` 同连接顺手 `cat`,app 进列表/back/onStart 各拉一次(零空轮询)。`xreal-project.sh` 自动部署 hooks。**老的 `StatusPoller`/`AgentStatusDetector` 抓屏轮询(`tmux capture-pane`)已被取代、仍 dormant**(`FleetFeatures.LIVE_STATUS=false` 不再是状态来源,别去翻它,见 §4)。**注意**:hooks 只给 state + 时长,**不给 preview(最近命令)文本** → 见 P2.2 |
| P2.2 | 列表卡片 **preview 文本(最近命令预览)** | ⏸️ 仍搁置 | 状态徽章(working/waiting/disconnected/unknown + 时长)已由 hooks 落地(P2.1);但 **preview 文本需抓屏**(`tmux capture-pane`),hooks 给不了 → 随老抓屏路径一起搁置。index.html `render` 的 `preview` 字段已能消费,数据源未接 |
| P2.3 | 舰队聚合 pills(顶部 需要你/工作中/未激活/已断开 计数) | ⬜ 未开始(列表 UI 精简时撤掉了顶部 `#fleet`) | 纯展示。**数据源 P2.1 已就绪(hooks 状态)**,缺的是顶部聚合 pills 这块 UI 本身。**注意:这才是用户说的"舰队导航",≠ P0.2 方向键导航** |
| P2.4 | WAITING 置顶 / 状态变化通知 | ⬜ 未开始 | 数据源 P2.1(hooks 状态)已就绪;缺排序/提醒逻辑。"哪个 agent 要我反馈"一眼可见 |
| P2.5 | Project 内多 session(tmux 多 window) | ⬜ 未开始 | 一个 project 内开**配角终端**(shell/git/日志 tail/REPL)—— 不是第二个 agent(并行 agent 由Maestro建多个 project,见 P1.1b)。映射:tmux session 内多 window。切窗口**复用 voice-overlay 那套**(按住一键 → 大字号 overlay 列窗口 → 方向键选 → 松手切),常驻占 0 行终端输出,6 键手柄上比 `prefix+n` 顺手。**体验升级,不急** |
| P2.6 | 项目级**热词管理 skill** | ⬜ 未开始 | 热词读取链路已就绪(`Hotwords.BASE` 继承 + manifest `projects[].hotwords` per-project 合并喂 ASR)。**这个 skill 负责"写"那张表**:project agent 定期回顾、从语音识别明显错误里总结新热词,用户授权后刷新进该 project 的热词表。**待定:存储位置** —— manifest `projects[].hotwords` 字段(Maestro 转写)vs `<projectDir>/.xreal/hotwords.json`(project agent 自管)。实做时再定 |
| P2.8 | **触摸翻页(旧半屏入口)** | ✅ 已被 P1.4 升级 | 旧入口是上半屏/下半屏翻页;iOS 现已升级为 P1.4 的 5-unit 热区 + 语音触发区。Android 锁横屏 + 物理键为主,按需补。 |
| P2.9 | session 驻留可配置(abduco/tmux/screen) | ⬜ 未开始(从 P1 降级) | `tmuxAttachCommand` 现在硬编 tmux;agent 类需 tmux(capture-pane),纯 SSH 可 abduco。做成 per-project 配置。不影响当前主流程,暂不抢 P1 |
| P2.10 | host 分组头展示 | ✅ 已有(从 P1 降级) | index.html `<div class="host">` 按 host 分组。non-core 但有用,先留着;若将来嫌乱可降级 |

### 富媒体预览设计(P1.3 —— 2026-06-01 立项,设计已收敛,未开工)

**动机**:终端只能吐字符,表现单一。host 上的 agent 经常产出图片(截图 / 渲染图 / 图表)或 HTML(报告 / diff / 预览),用户在 AR 眼镜下没法离开 app 去开浏览器看。给 app 加一个**只读全屏富媒体预览层**,让 agent 一句话把图/页推到用户眼前。

**两条硬决策(都被既有约束逼定,不是自由选型)**:

1. **传输走 SSH :22,不做 host web server**。用户最初提的"host 上跑个 web 服务器"方案**违反零服务端增量硬约束**(CLAUDE.md §5:不引 ttyd/nginx/任何云端服务)→ 排除。改用已有 SSH 通道:client 开**一条独立短命 exec channel** 跑 `base64 <path>` 把文件字节拉回本地(**与现有 `HostClient.catFile` 拉 manifest/status 完全同模式**),WebView 本地渲染。
2. **触发走 PTY 流内哨兵(in-band sentinel),不轮询文件**。host→client 唯一的 push 通道 = client 正在读的 PTY 流(client 事件驱动、不空轮询是既定偏好)。skill 往 stdout 打一个**对用户不可见的 OSC 转义序列**,载荷 = `{kind, path}`(**只带 host 上绝对路径引用,不内联字节**——大图 base64 灌进交互 PTY 会被 tmux 截断/卡渲染;引用 + 独立 exec 拉取更稳、能处理大文件)。

**数据流**:
```
host agent:  .xreal/xreal-preview ./out.png
   → 判 kind(扩展名 / file --mime)、path 绝对化
   → 打 tmux-passthrough 包裹的 OSC 哨兵 {kind:"image", path:"/abs/out.png"}  ──PTY──▶
client xterm.js:  registerOscHandler 解析 → Bridge.openPreview(kind, path)
   → 原生侧独立 exec channel:  base64 <path>   ──SSH :22──▶  拿字节
   → window.showPreview(kind, dataUri)  →  全屏 overlay <div>
       image →  <img> fit-to-screen;方向键 pan(放大后)/ zoom;ESC/返回 关
       html  →  <iframe sandbox srcdoc>(默认无 allow-scripts → 静态渲染,够"只看")
```

**⚠️ 头号技术风险 = tmux 拦截哨兵**:client 读到的是 **tmux 渲染层**,不是程序原始 stdout。tmux 默认**不转发未知 OSC** → 哨兵到不了外层 xterm.js。解法:skill 用 **tmux passthrough** 包裹(`\ePtmux;<ESC-seq>\e\\`)+ client 注入的 tmux conf 加一行 `set -g allow-passthrough on`(**已经在 `MainActivity.tmuxAttachCommand` 用 `-f conf` base64 注入 history-limit/翻页 bindings,加这一行同源、零服务端增量**)。纯 SSH/abduco(无 tmux)时哨兵直达 xterm.js,不用包裹。

**服务端侧 = 一个 skill/脚本(零增量)**:`xreal-preview <file>` 纯 bash,放 host 的 `.xreal/`(已授权的唯一例外目录,与 `xreal-project.sh`/`agent-status.sh` 同级);可同时包成 Claude Code skill `/preview <file>` 让 agent 直接调。判 kind + 绝对化 path + 打哨兵,**无 daemon / 无端口 / 无依赖**。

**输入语义(SPEC §6 扩展,层栈 list → terminal → preview)**:
- **方向键** = pan(放大后)/ zoom,**不透传给 SSH**(预览层吃掉)。
- **ESC(硬件键)/ F2(8BitDo 返回)** = **关预览层退一层回 terminal**,不直接回 list。即"返回"语义升级成"退出当前最上层"。
- 物理映射沿用 per-device 表(Beam Pro:方向键 = 8BitDo DPAD;关闭 = F2)。

**安全契约**:
- 预览 overlay / iframe **绝不能访问 `TerminalBridge`**——HTML 走 `<iframe sandbox>`(默认无 `allow-scripts`、无 `allow-same-origin`),防恶意/失控 HTML 反向触达 SSH 输入或 bridge。
- 拉取文件**大小上限**(建议图 ≤ 8MB / html ≤ 2MB),超限拒绝。
- **kind 白名单**:image(png/jpg/webp/gif)、html;其它 kind 拒绝。path 来自 host(同 SSH 用户,可信),但仍 cap size + 白名单兜底。

**分期**:
- **v1**:图片(png/jpg/webp/gif)。最小闭环:哨兵 → 拉取 → 全屏渲染 → 方向键 pan → ESC 退。
- **v2**:静态 HTML(`<iframe sandbox srcdoc>` 无脚本)。**自含单文件**;带相对资源/外链的 HTML 暂不支持(要支持需 tar 目录或内联资源,后置)。
- **v3(可选)**:带脚本 HTML(图表等)需放开 `allow-scripts`,安全面变大,单独评估。

**跨端**:协议(哨兵格式 / kind 枚举 / 拉取约定 / overlay 行为 / 输入语义 / 安全)= **SPEC §13**,Android/iOS 同实现。平台落点:Android = WebView overlay div + xterm.js OSC handler + sshj exec;iOS = WKWebView + 同 `index.html` overlay + Citadel exec channel。

**接口点(开工时挂这些,搁置也留着)**:① `TerminalBridge` 加 `@JavascriptInterface openPreview(kind, path)`;② native 侧复用 `HostClient` 式独立 exec 拉 `base64`;③ `index.html` 加 `window.showPreview(kind, dataUri)` + 全屏 overlay + OSC handler 注册;④ `tmuxAttachCommand` 注入 `set -g allow-passthrough on`;⑤ 输入路由把预览层打开态纳入层栈(方向键/ESC 拦截)。

---

### §4(历史 · 已作废)旧的抓屏路径接回清单

> **⚠️ 2026-05-31:状态展示已改走 hooks(P2.1 ✅),下面这套抓屏(`tmux capture-pane`)接回清单不再是获取状态的方式,别照它去 `LIVE_STATUS=true`(那是已死路径,翻它没用)。** 整套 `StatusPoller`/`AgentStatusDetector`/校准测试代码仍保留,但只在将来要补 **preview 文本(最近命令预览,P2.2)** 时才可能用得上 —— 因为 hooks 给不了 pane 文本内容。即便那时,也只是作为 preview 的数据源,而非状态来源。下面原文留作那个场景的参考:

1. ~~**开开关**:`FleetFeatures.LIVE_STATUS = true`~~(已作废 —— 状态走 hooks,见 P2.1)
2. **生命周期已挂好**:`MainActivity.onStart/onStop` 已 `poller?.start()/stop()`。
3. **校准检查**:`AgentStatusDetector` 启发式按 **Claude Code v2.1.153** 标定(WORKING 看 "esc to interrupt";WAITING 看 "Do you want to proceed?"+"❯ 1.")。TUI 改版后要重标 —— 跑 `AgentStatusDetectorTest` + `ClaudeCodePaneCalibrationTest`(fixtures 在 `test/resources/panes/`)。
4. **JSON 形状契约(注意:这条本身仍 live,不属于作废范围)**:`StatusPoller.Companion` 的 `projectJson`/`hostJson` → `window.setHosts`/`render` **就是当前列表渲染用的契约**(`StatusPoller.staticListJson` + `ManifestFetcher` 并入 hooks 状态都走它)—— **作废的只是上面 capture-pane 那个数据源,不是这个 JSON 形状**。改列表 JSON 时两端别漂移。形状 `[{name,addr,up,projects:[{name,type,status,age,preview}]}]`,`preview` = null 或 `{glyph,text,cur}`(`preview` 当前恒 null,见 P2.2)。

---

## 不在路线图内(明确不做)

- 服务端增量(ttyd / nginx / 云端 Voice Gateway / tmux-send-keys daemon)—— 零服务端增量是硬约束
- 双进程架构(主 app + 辅助 service)—— 单 APK 闭环
- `SYSTEM_ALERT_WINDOW` / Accessibility / IME —— overlay 走 WebView 内 HTML,输入走 `dispatchKeyEvent`

(以上见 CLAUDE.md §5 关键约束,经 4-5 轮收敛,不重新挑战。)
