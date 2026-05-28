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
| P1.1 | Host/Project 录入 UI | ⬜ | 替掉 adb push `xreal_hosts.json`。`SettingsStore.loadHosts()` 当前只读 `/data/local/tmp` 的 JSON。需要在 app 内增删 host + 持久化 + 私钥导入 |
| P1.2 | 真豆包 ASR(替 mock) | ⬜ | 需 Volcengine creds。`VoiceDaemon` 已留 ASR 接口,接真实 AudioRecord→Opus→豆包 |
| P1.3 | session 驻留可配置(abduco/tmux/screen) | ⬜ | `tmuxAttachCommand` 现在硬编 tmux;agent 类需 tmux(capture-pane),纯 SSH 可 abduco。做成 per-project 配置 |
| P1.4 | host 分组头展示 | ✅(已有) | index.html `<div class="host">` 按 host 分组。**non-core 但有用**,先留着;若将来嫌乱可降级 |

---

## P2 — 体验增强(已搁置,留接口随时接回)

不影响主流程打通。这是"AI agent 集群指挥台"愿景(见 memory `product-vision`)的差异化部分,但**核心流程能跑之后再接**。

| # | 需求 | 状态 | 接口/开关 |
|---|---|---|---|
| P2.1 | 实时状态刷新(WORKING/WAITING/preview 探测) | ⏸️ 搁置 | `FleetFeatures.LIVE_STATUS=false`。置 true 即恢复 `StatusPoller` 5s 轮询 `tmux capture-pane` |
| P2.2 | 列表卡片状态展示(徽章 + preview 文本) | ⏸️ 搁置 | 依赖 P2.1。index.html `render` 的 `STATUS`/`preview` 已能消费,数据来源关了就一律 IDLE/无 preview |
| P2.3 | 舰队聚合 pills(顶部 需要你/工作中/未激活/已断开 计数) | ⏸️ 搁置(随 P2.1) | index.html `#fleet`。纯展示,数据来自 P2.1;关了显示全 0/全 idle。**注意:这才是用户说的"舰队导航",≠ P0.2 方向键导航** |
| P2.4 | WAITING 置顶 / 状态变化通知 | ⬜ 未开始 | 依赖 P2.1。"哪个 agent 要我反馈"一眼可见的排序/提醒 |

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
