# ROADMAP — 分级需求跟踪

> 按**优先级分层**跟踪需求,而不是按 phase。判据是:**这条断了,整体流程还能不能打通?**
> - **P0 核心**:断了 = app 不可用。**已全部打通**(Beam Pro X4100 真机日常用);焦点已移到 P1 收尾 + P2。
> - **P1 可用性**:当前未完成 P1 = **富媒体预览**。其它未完成项默认降到 P2/P3,不抢主线。
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
| P0.3 | per-project 真 SSH 终端(attach tmux,含**多跳**) | ✅ | `onOpenProject`→`SshConnection`+`tmuxAttachCommand`;channel 热切(`switchTo`/`startReaderFor`)。**多跳 SSH(ProxyJump)已落地**:`HostConfig.via` + `SshJump`(sshj 本地端口转发),private-worker via jump-edge 端到端认证(private-worker 在 AWS 内网,只 jump-edge 的 OpenVPN 可达)。 |
| P0.4 | 终端显示(xterm WebGL + 中英文 + powerline + **翻页**) | ✅ | Meslo(Latin/powerline)+ Sarasa(CJK)+ WebGL 字体就绪;远端 `tmux -u` + UTF-8 locale。**tmux 半页翻页**:Shift+↑/↓ → root 表进 copy-mode(不与 Claude Code 冲突)+ history-limit 50000(`-f conf` 注入,服务端零增量)。 |
| P0.5 | 硬件键路由(+ 虚拟键盘兜底) | ✅ | `dispatchKeyEvent` 路由 **F1=语音 / F2=返回**(Stage A.1 实测:Beam Pro 的 8BitDo F13–F24 被 `Generic.kl` 注释、到不了 app;F13/F14 + Ctrl+Alt+1/2 分支保留作兜底)。**虚拟键盘动态显隐**:8BitDo 插拔实时切(插着隐、拔了出),去掉多余 hint 说明条 |
| P0.6 | 语音 daemon 状态机(overlay show/hide + Enter 注入) | ✅ | 骨架完成,ASR 仍是 mock(真豆包见 P1.2) |
| P0.7 | BACK 返回列表 / 优雅降级 | ✅ | BACK 键 + home 键;SSH 失败回退 LocalEcho 不卡 |

> P0 当前**已全部打通并在 Beam Pro X4100 真机日常用**(双 host:jump-edge 直连 + private-worker 经 jump-edge 多跳,各跑 Maestro)。物理设备项(8BitDo F1/F2、真麦克风)已实测。
>
> **可观测性(支撑性,非 P0 闭环)**:持久化日志 + 崩溃捕获已落地 —— `AppLog` 写外存(`adb pull`,不需 run-as)+ `XrealApp` 全局未捕获异常处理器落盘崩溃。出问题先 `adb pull` 取证。

---

## iOS 原生化 + 交互(2026-06 立项,逐项推进)

> iOS 第二客户端从「WKWebView 跑共享 index.html」走向 **全面原生**。起因:WKWebView 收不到硬件键 DOM + 软键盘抑制死结(终端);后续列表也升级成标准 iPhone 体验。**做法:一项一项做,做完一项验一项**。契约仍归 SPEC,平台落点(SwiftTerm/UITableView)进 §11 矩阵。

| # | 任务 | 状态 | 说明 |
|---|---|---|---|
| iOS.1 | **终端改原生 SwiftTerm** | ✅(2026-06-01) | 替代 WKWebView+xterm,解键盘死结。键盘全原生正确(字母/Tab/Shift+Tab/方向/Ctrl/DECCKM);F1/F2 + 语音 Enter/Esc 经 swizzle 拦;软键盘抑制 inputView 0 高;tmux 翻页 conf 注入。字体按 Android 方案打包 Sarasa/Meslo,CoreText 注册;SwiftTerm 单字体优先 Sarasa |
| iOS.2 | **触屏 vkey(无硬件键盘)** | ✅ | 无 8BitDo 时终端挂原生 `TerminalKeyBar`(inputAccessoryView):返回/方向/Enter/Esc/删词/Ctrl-B/模式/Ctrl-C/🎤;横屏 1 行竖屏 2 行;键盘避让(终端缩到 vkey 上);按键震动 + 高亮 |
| iOS.3 | **终端触摸翻页** | ✅ | 5-unit 热区翻页统一发 S-Up/S-Down 走 tmux copy-mode;Claude Code 的 PageUp/PageDown 路径不稳定。触摸翻页加短节流,cue 不再快速闪烁;tmux mode-style 调淡以减轻 copy-mode 重绘白块感 |
| iOS.4 | **列表改原生(苹果设计语言)** | ✅ | WKWebView/index.html 退出 iOS(只留 Android)。`DeckListView`(insetGrouped UITableView + SF Symbols + 系统色状态徽章 + disclosure + 下拉刷新)+ `DeckNavController` 大标题「Deck」。点 cell 进 project、滑动滚动、物理键方向/Enter 导航 |
| iOS.5 | **列表状态栏 / 终端全屏** | ✅ | 列表态恢复标准 iOS chrome(状态栏 + nav bar 大标题);终端态沉浸全屏(隐藏状态栏 + home indicator + nav bar)。`DeckNavController` 把状态栏决定权转发给顶层 VC |
| iOS.6 | **边缘滑动手势** | ✅ | **列表页**:右侧较宽区域左滑 → 打开**最近一次打开的终端**;**终端页**:左缘或内容区明显右滑 → 回列表。terminal 跟手滑动,垂直滚动/点按翻页不抢 |
| iOS.7 | **最近终端保活(keep-warm)** | ✅ | 离开终端后 90s 内不 close tmux/SSH,保留 SwiftTerm 绘制状态;滑入前预热/缓存 vkey 高度并先摆好 offscreen frame;返回列表时临时卸掉 vkey + 用底部 cover 隔离 hide 动画,首帧不 reload table;超时真正 close |
| iOS.8 | **SSH-over-443 / vmess** | ✅ 真机验证 | HostStore 支持 host 内联 `proxy{name,localPort,url}` 并拒绝本地端口冲突;列表 host header 显示 `🔒 proxy`;`SshConnect` 统一处理终端 + manifest/status 轮询,按 proxy/via 归属起 host 级 xray dokodemo-door(override→服务端 `127.0.0.1:22`)并让 Citadel 直连该 host 固定本地口。未 build framework 时带 proxy host fail closed,直连不受影响 |

---

## P1 — 当前高优先级

> 2026-06-01 重排:Host 接入 / manifest / ASR 等是已完成基线;session 驻留可配置、preview 文本、fleet pills、通知、多窗口、热词管理等全部降到 P2。当前 P1 只放真正影响触屏可用性的工作。

| # | 需求 | 状态 | 备注 |
|---|---|---|---|
| P1.1 | Host 接入 = 代客安装 (Valet Setup),**无 UI** | ✅ 基本完成 | **刻意不做设置 UI**。Valet agent 经 adb push key+config → staging,app 导入私有存储(`SettingsStore.importStagingIfPresent`:key 设 600、原子写、用完删 staging、legacy 回退)。引导:`docs/agent-setup-guide.md`。剩 host 录入 UI 永不做 |
| P1.1b | Maestro CLAUDE.md + manifest 契约 | ✅ 文档 | `docs/orchestrator-CLAUDE.md` 定义角色 + manifest schema(`<base>/.xreal/projects.json`,Maestro写 app 读)。base path 存 app 配置(Valet 写),不存 manifest(防循环信任) |
| P1.1c | app live-fetch manifest | ✅ 真机验证 | `ManifestFetcher` 经 `HostClient.catFile` 拉 `<basePath>/.xreal/projects.json` → `liveProjects`(findProject 按 **session** 查、seed 兜底)→ `pushHostList` 内容去重防闪烁。**刷新 = 事件驱动零空轮询**:列表首显 / back-to-list / onStart 各拉一次(`fetchExec` 单线程串行 + `fetchGen` 防乱序;拉取失败保留当前列表)。Maestro 改 manifest → 回列表即现 |
| P1.2 | 真豆包 ASR(替 mock) | ✅ 真机验证 | **真双向流式**(`bigmodel_async` WS,`VolcFrame` 二进制协议+gzip)。按住即连 WS、`AudioRecorder` 边录边吐 200ms 裸 PCM 块(非 Opus)、中间结果实时上屏、松手发负包拿 final。会话式 `Asr` seam(`open/send/finish/cancel`+回调);race 防御=generation counter + `cancelled`/`done`。creds 走 Valet `asr.json`(无 UI)。**热词**:`corpus.context` 内联,`Hotwords.BASE`(Claude Code 控制命令)所有 project 继承 + manifest per-project 合并、按 token 预算 cap。语音键收为单 🎤。`VolcFrame`/`PcmChunker` 有 JVM 单测 |
| P1.3 | **富媒体预览(agent 产出 URL → 系统浏览器打开)** | ⬜ 未开始 | 见下「§ 富媒体预览设计(2026-06-02 简化)」。**零客户端改动**:host 上起 HTTP server(Valet 装一次),agent 产出图片/HTML 报告时输出完整 URL → 用户手机浏览器打开。app 不做 OSC 解析、不做 overlay、不做文件拉取。**限定**:仅直连公网 host(经 jump/隧道的 host 本期不支持)。⚠️ **前提**:当前 terminal 全屏触摸区被翻页/语音手势吃满,链接无法点击;需在终端加一个 URL 检测 + "在浏览器打开"手势/入口 |
| P1.4 | **terminal 触摸热区 + 语音 overlay 点击语义** | ✅ iOS 真机验证 | 只按 terminal 核心显示区计算,有 vkey 时先排除 vkey。核心区纵向 5 份:top 2 unit = 上翻页,中间 2 unit = 下翻页,bottom 1 unit 的底部 2/3 = hold-to-talk 语音热区;翻页触发时用半透明区域 overlay 覆盖整个触发区,叠加加大加粗箭头并短暂驻留,让用户看清范围。overlay 出现后翻页自然失效,核心区只剩 3 块:overlay 卡片点击 = Enter 注入识别文本,卡片上方点击 = Esc 取消,卡片下方按压 = 重新录音。契约 = SPEC §6 |

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

不影响主流程打通。这是 Agent Station / Agent 工作站("a mobile command station for AI agents")愿景的差异化部分,但**核心流程能跑之后再接**。

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

### 富媒体预览设计(P1.3 —— 2026-06-02 简化,零客户端改动)

**动机不变**:终端只能吐字符。host 上的 agent 经常产出图片(截图/图表)或 HTML(报告/diff/预览)。用户需要看到这些内容。

**核心洞察(推翻了 2026-06-01 的设计)**:不需要 app 内预览层。最丰富、最完整的交互体验 = **系统浏览器**。不做 OSC 哨兵 → 文件拉取 → WebView overlay 这一整条链。

**方案**:

```
host 侧(Valet 装一次):
  装 nginx/caddy/python-http-server,配 web root(如 <base>/.xreal/www/),开端口(如 8443)

agent 产出文件:
  cp out.png <base>/.xreal/www/screenshots/
  → 输出 "截图: https://<host>:8443/screenshots/out.png"

用户在终端里看到 URL → 在浏览器里打开
```

| 层 | 做什么 | 谁做 |
|---|---|---|
| HTTP server | 装一次,配 web root + 端口,防火墙开好 | Valet agent(host 接入时) |
| 文件产出 | agent 把文件 cp/mv 到 web root 下 | project agent |
| URL 输出 | agent 知道 web root 路径和 base URL,组装完整链接,写入终端 | project agent(CLAUDE.md 交代) |
| 浏览 | 用户看到链接,在手机浏览器打开 | 用户 |

**app 端改动 = 零**。不需要 OSC 解析、不需要文件拉取、不需要 overlay。

**⚠️ 前提条件(当前阻塞)**:Android `index.html` 和 iOS 的终端页**整个触摸区被翻页手势(5-unit 热区)+ 语音 hold-to-talk 吃满**,终端内链接无法被点击。

- **iOS**:`TerminalViewController` 的 `handleTermPageTap` / `handleTermVoicePress` / `handleTermReturnPan` 瓜分了整个 `term.frame`;SwiftTerm 自身的文本选择手势已被禁掉(`isEnabled = false`)
- **Android**:终端可视区没有链接点击处理;`index.html` 的键盘事件监听在 terminal 态交给 xterm

**解法(本期做)**:终端态增加一个**链接检测 + 打开入口**——xterm/SwiftTerm 检测到 URL pattern → 提供快捷方式(比如长按 / 底部出现"在浏览器打开"条 / 或 F1 长按触发)。不改变翻页/语音手势的现有行为。

**限定**:**仅直连公网 host 有效**。经 jump(ProxyJump)的 host 和经 SSH-over-443 隧道(vmess)的 host 本期不支持 —— 手机浏览器无法到达内网 host,也不在 xray 隧道里。

**host 侧交付物**:
- Valet agent 脚本:装 HTTP server(如 `python3 -m http.server` 或 caddy)、配 web root(`<base>/.xreal/www/`)、开端口、防火墙
- Maestro handoff:告诉每个 project agent web root 路径 + base URL,让它知道"产出文件放到哪、链接怎么拼"

**跨端**:无需 SPEC 契约(无 app 端行为)。host 上的配置在 agent-setup-guide 里记。

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
