# ROADMAP — 分级需求跟踪

> 按**优先级分层**跟踪需求,而不是按 phase。判据是:**这条断了,整体流程还能不能打通?**
> - **P0 核心**:断了 = app 不可用。当前焦点,优先做完、做对。
> - **P1 可用性**:核心打通后优先补,影响"能不能脱离 dev rig 真正用起来"。
> - **P2 体验增强**:不影响主流程,可随时搁置 / 接回。**搁置的必须留接口 + 在本文件记接回清单**。
>
> 维护规则:状态变化随手改这里(✅ done / 🚧 进行中 / ⏸️ 搁置 / ⬜ 未开始)。搁置一个功能时,把它的接口点写进 §4「接回清单」。

---

## P0 — 核心流程(整体打通,当前焦点)

最小端到端闭环:**开 app → 看到真实项目列表 → 键盘导航 → Enter 开真 SSH 终端 → 打字(硬件键+虚拟键盘)/语音 → BACK 回列表**。任何一环断了主流程就断。

| # | 需求 | 状态 | 备注 |
|---|---|---|---|
| P0.1 | 列表静态枚举真实 host/project | ✅ | `StatusPoller.staticListJson` → `onPageFinished` 推 `window.setHosts`。**这是开真终端的前提**(Enter→`findProject` 靠名字匹配) |
| P0.2 | 列表键盘导航(方向键 + Enter) | ✅ | index.html `setFocus`/`keydown` + 虚拟键盘 `vkey`。**键盘专用 app 的命根子,任何时候都不能移除**(≠ §P2 的舰队聚合 pills) |
| P0.3 | per-project 真 SSH 终端(attach tmux) | ✅ | `onOpenProject`→`SshConnection`+`tmuxAttachCommand`;channel 热切(`switchTo`/`startReaderFor`) |
| P0.4 | 终端显示(xterm WebGL + 中英文 + powerline) | ✅ | Meslo(Latin/powerline)+ Sarasa(CJK)+ WebGL 字体就绪;远端 `tmux -u` + UTF-8 locale |
| P0.5 | 虚拟键盘 + 硬件键路由 | ✅ | 一行虚拟键盘;`dispatchKeyEvent` 路由 F13/F14(+ Ctrl+Alt+1/2 备路径) |
| P0.6 | 语音 daemon 状态机(overlay show/hide + Enter 注入) | ✅ | 骨架完成,ASR 仍是 mock(真豆包见 P1.2) |
| P0.7 | BACK 返回列表 / 优雅降级 | ✅ | BACK 键 + home 键;SSH 失败回退 LocalEcho 不卡 |

> P0 当前**已全部打通**(emulator + Beam Pro X4100 真机验证)。剩余 P0 风险是物理设备项(Stage A.1 8BitDo 真键、真麦克风),留 Phase 1。

---

## P1 — 可用性 / 录入(核心打通后优先)

让 app 脱离 dev rig(`scripts/setup-mac-host.sh` + adb push)也能真正用起来。

| # | 需求 | 状态 | 备注 |
|---|---|---|---|
| P1.1 | Host 接入 = 代客安装 (Valet Setup),**无 UI** | ✅ 基本完成 | **刻意不做设置 UI**。Valet agent 经 adb push key+config → staging,app 导入私有存储(`SettingsStore.importStagingIfPresent`:key 设 600、原子写、用完删 staging、legacy 回退)。引导:`docs/agent-setup-guide.md`。剩 host 录入 UI 永不做 |
| P1.1b | Maestro CLAUDE.md + manifest 契约 | ✅ 文档 | `docs/orchestrator-CLAUDE.md` 定义角色 + manifest schema(`<base>/.xreal/projects.json`,Maestro写 app 读)。base path 存 app 配置(Valet 写),不存 manifest(防循环信任) |
| P1.1c | app live-fetch manifest | ⬜ | 剩余项:app 进列表时 SSH `cat <base>/.xreal/projects.json` → 替换 Valet 推的 seed 项目。需 parser 读持久化的 `basePath`。落地后Maestro新建项目自动出现在列表 |
| P1.2 | 真豆包 ASR(替 mock) | ⬜ | 需 Volcengine creds。`VoiceDaemon` 已留 ASR 接口,接真实 AudioRecord→Opus→豆包 |
| P1.3 | session 驻留可配置(abduco/tmux/screen) | ⬜ | `tmuxAttachCommand` 现在硬编 tmux;agent 类需 tmux(capture-pane),纯 SSH 可 abduco。做成 per-project 配置 |
| P1.4 | host 分组头展示 | ✅(已有) | index.html `<div class="host">` 按 host 分组。**non-core 但有用**,先留着;若将来嫌乱可降级 |

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
| P2.1 | 实时状态刷新(WORKING/WAITING/preview 探测) | ⏸️ 搁置 | `FleetFeatures.LIVE_STATUS=false`。置 true 即恢复 `StatusPoller` 5s 轮询 `tmux capture-pane` |
| P2.2 | 列表卡片状态展示(徽章 + preview 文本) | ⏸️ 搁置 | 依赖 P2.1。index.html `render` 的 `STATUS`/`preview` 已能消费,数据来源关了就一律 IDLE/无 preview |
| P2.3 | 舰队聚合 pills(顶部 需要你/工作中/未激活/已断开 计数) | ⏸️ 搁置(随 P2.1) | index.html `#fleet`。纯展示,数据来自 P2.1;关了显示全 0/全 idle。**注意:这才是用户说的"舰队导航",≠ P0.2 方向键导航** |
| P2.4 | WAITING 置顶 / 状态变化通知 | ⬜ 未开始 | 依赖 P2.1。"哪个 agent 要我反馈"一眼可见的排序/提醒 |
| P2.5 | Project 内多 session(tmux 多 window) | ⬜ 未开始 | 一个 project 内开**配角终端**(shell/git/日志 tail/REPL)—— 不是第二个 agent(并行 agent 由Maestro建多个 project,见 P1.1b)。映射:tmux session 内多 window。切窗口**复用 voice-overlay 那套**(按住一键 → 大字号 overlay 列窗口 → 方向键选 → 松手切),常驻占 0 行终端输出,6 键手柄上比 `prefix+n` 顺手。**体验升级,不急** |

### §4 接回清单(P2.1 实时状态刷新)

搁置时**代码全部保留**,接回只需:

1. **开开关**:`FleetFeatures.LIVE_STATUS = true`(`FleetFeatures.kt`)。一行。
2. **生命周期已挂好**:`MainActivity.onStart/onStop` 已 `poller?.start()/stop()`,无需改。
3. **校准检查**:`AgentStatusDetector` 的启发式按 **Claude Code v2.1.153** 标定(WORKING 看 "esc to interrupt";WAITING 看 "Do you want to proceed?"+"❯ 1.")。Claude Code TUI 改版后可能要重标 —— 跑 `AgentStatusDetectorTest` + `ClaudeCodePaneCalibrationTest`(fixtures 在 `test/resources/panes/`)。
4. **JSON 形状契约**(单一来源,别让两端漂移):
   - Kotlin 侧:`StatusPoller.Companion`(`staticListJson` / `pollOnce` 共用 `projectJson`/`hostJson`)
   - JS 侧:index.html `window.setHosts` / `render`
   - 形状:`[{name,addr,up,projects:[{name,type,status,age,preview}]}]`,`preview` = null 或 `{glyph,text,cur}`
5. **静态 vs 实时如何叠加**:开关关时只推一次静态枚举(全 IDLE);开关开时 poller 每 5s 用真实状态**整批覆盖**同一份列表。两者走同一个 `pushHostList` → `window.setHosts`。

---

## 不在路线图内(明确不做)

- 服务端增量(ttyd / nginx / 云端 Voice Gateway / tmux-send-keys daemon)—— 零服务端增量是硬约束
- 双进程架构(主 app + 辅助 service)—— 单 APK 闭环
- `SYSTEM_ALERT_WINDOW` / Accessibility / IME —— overlay 走 WebView 内 HTML,输入走 `dispatchKeyEvent`

(以上见 CLAUDE.md §5 关键约束,经 4-5 轮收敛,不重新挑战。)
