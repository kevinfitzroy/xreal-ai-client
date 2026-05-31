# HANDOFF — 当前实际进度与下一步

> 状态交接给**下一个接手的 Claude Code session**。CLAUDE.md 是永久指南,这里是动态状态。
> **最近更新**:2026-06-01(**第三客户端 HarmonyOS 立项**:脚手架 + ~1900 行 ArkTS 骨架 + 文档,见 [`harmony/`](harmony/);上一轮:第二客户端 iOS 定调 + 真机闭环;ROADMAP P2.7 富媒体预览 + SPEC §13)

---

## 0.0' 本轮(2026-06-01)—— 第三客户端 HarmonyOS 立项(代码+文档,未编译)

无编译环境下尽量备好:`harmony/` 独立目录,照 Android+SPEC 写 **ArkTS/ArkUI 工程骨架 + 27 个 .ets(~1900 行)+ cpp NAPI 骨架 + 4 份文档**。核心(终端 Web+桥、列表/manifest、语音、按键、配置)代码完整;**SSH 两条 backend 都起骨架**(A=libssh2/NAPI 类 sshj、B=纯 ArkTS over TCPSocket+cryptoFramework 类 Citadel),**选哪条是悬置的人工决策**(`harmony/docs/DECISIONS.md` D1)。SPEC §11.1 加了 HarmonyOS 列。
- **下个 session / 用户上线先看**:`harmony/README.md` → `harmony/docs/DECISIONS.md`(拍板 SSH backend)+ `HUMAN-TASKS.md`(装 DevEco/签名/真机/交叉编译 libssh2)。
- **已知差异**:ArkWeb 桥跑主线程(SSH 写必派后台)、键事件组件焦点级(须抢焦)——代码已处理。
- **未做(等环境/决策)**:编译验证、SSH backend 完成、SSH-over-443 隧道接入、真机验 8BitDo/麦克风/眼镜。

---

## 0.0 当前状态(2026-05-31)—— 先读这条

### 🆕 本轮:走向双客户端(Android + iOS),先立契约

两件事落地,方向也变了:

1. **首个签名 release v0.2.0**(针对 Beam Pro 的 sideload APK):https://github.com/kevinfitzroy/xreal-ai-client/releases/tag/v0.2.0
   - 正式签名(`debuggable=false`,app 持 SSH 私钥,不发 debug 包),keystore 在 `android/release.jks` + `android/keystore.properties`(**均 gitignored,用户须 git 外备份**——丢了无法发签名更新)。
   - 意义:未来装机**不需要编译环境**,`adb install -r` 即可;但**代客安装(hosts/key 注入)的 adb 通道不变**,仍刻意无设置 UI。详见 README「从 Release 安装」+ SPEC §8/§11。

2. **第二客户端方向定调 = iOS**(用户决策,2026-05-31)。前提已核实成立:
   - **Beam Pro 非必选**:XREAL One Pro 吃任何 USB-C DP 信号源。**iPhone 15/16(非 e、非 Air)**有 DP Alt Mode 可直连眼镜(16e/Air 砍了 DP、14 及更早 Lightning → 接不了)。
   - **iOS 能被 AI 便捷开发,但便捷度不对称**:模拟器(`xcrun simctl`,本机 **Xcode 26.4 + iPhone 17 模拟器就绪**)装/起/截屏**零签名**,AI 友好度≈优于 adb;**真机**被**代码签名门**卡(每次装机需 Xcode + Apple 账号,用户目前**仅免费 Apple ID = 证书 7 天**),真机截屏走 `pymobiledevice3 developer dvt screenshot`。所以 **iOS 开发模拟器优先**,硬件路径(8BitDo/麦克风/DP-眼镜)上真机由用户验——与 Android「硬件部分用户验」同构。
   - **架构差异点(iOS 必然重设计)**:无前台 Service → Voice Daemon 改 background audio mode;物理键走 `GameController` framework;配置注入无 `adb push` 等价物(SPEC §8 注记,POC 要定这条通道)。

3. **抽出平台中立契约层 [`SPEC.md`](SPEC.md)(Contract version 1)** —— 防双端内耗的根。host/project 列表、状态 4 态、语音 🎤 注入、按键语义、ASR 热词、hosts.json/status.json 形状、安全规则,**只在 SPEC 定义一次**,两端实现它。平台落点(sshj/WKWebView/Service 等)进 SPEC §11 矩阵,不进契约正文。**改任何跨端行为先改 SPEC 再两端对齐**(§12 流程)。

**✅ iOS POC + 正式客户端 Phase 1 已验通(2026-05-31,`ios/`,模拟器,均截图 Read 确认)**:
- **POC**:WKWebView **原样跑 Android 的 `index.html`(零改动)** + `window.Bridge` shim→`messageHandlers` Base64 桥 + 字体(file:// 无跨域)+ WebGL + Citadel SSH 真 PTY,全通。
- **Phase 1 核心闭环**:`hosts.json → Agent Deck 列表(cat manifest)→ 开 project → ed25519 SSH → tmux PTY → 返回`,**port 自 Android**(双轨 channel:manifest 走独立短命 exec / project 走交互 PTY;`syncSize` 热切重推尺寸;`openSeq`+`sessionGen` race 守护;`tmux -u`+UTF-8)。新增 Swift `Models/HostStore/ManifestFetcher` + 进化 `SSHSession/TerminalViewController`。本地 Mac host(127.0.0.1,`~/.ssh/xreal_phase0` ed25519,已授权)验通。
- **Phase 1 UI**(用户要求,SPEC §6.1):横竖兼容(旋转 `fitAddon` 重排)+ 虚拟键盘**横屏 1 行 / 竖屏 2 行**(共享 `index.html` 加一个 `@media(orientation:portrait)`,两份 byte-identical;Android 锁横屏→永远 1 行→零影响)+ 蓝牙键盘 connect→`setHwKeyboard` 隐藏。
- 工程 xcodegen;一批 `#if DEBUG`+launch-arg 验证脚手架(gated,生产零影响,类似 Android `DebugInputServer`)。
- **Phase 2 状态徽章已验通**:列表 `cat <base>/.xreal/status.json`(同连接,port `ManifestFetcher.parseStatus` 数组 schema + `StatusPoller.staticListJson` 合并:不可达→disconnected/有上报→用/无→unknown)+ 返回列表重拉。截图验 working/waiting/needs-permission/unknown/disconnected 五态 + age + refresh。改动仅 3 个 `ios/App/Sources/*.swift`,未碰 index.html/android。
- **Phase 3 健壮性收尾已验通**:① 前台重拉(`willEnterForeground`,LIST 态→refresh,Android `onStart` 对等);② **死 host 不 hang 列表**(`withTaskGroup` 并发 + 7s 硬超时 + 非结构化 Task 逃逸 —— 黑洞 host TCP 不响应 cooperative cancel,必须外部超时;实测活 host 0.3s 出来、黑洞 7s 翻 offline 不拖累活 host);③ PTY 掉线优雅(`onClosed` 黄字提示不 crash/冻,`tmux new -A` reopen 重连;`live` flag + `ssh===s` guard 消重复"连接失败"误报);④ per-host 增量 loading;⑤ 优雅降级 `webContentProcessDidTerminate` 自愈回列表(SPEC §9)。改 4 个 ios Swift。
- **Phase 4 多跳 `via` ProxyJump 已验通**:**Citadel 0.12 有原生 `SSHClient.jump(to:)`**(在跳板上开 directTCPIP channel + 第二次完整握手)→ **不需要** port Android 的 `ServerSocket`+`LocalPortForwarder`(那是 sshj 无原生 ProxyJump 才手搓的);功能塌缩成「换种方式拿 SSHClient」,下游 `executeCommand`(cat)/`withPTY`(PTY)不变。新增 `SshConnect.swift`;`via` 解析接进 manifest-cat 和 PTY 两条路(死跳板仍被 7s 超时框住)。本地两跳 rig(跳板 :22 + 内网 sshd :2223)验通,**lsof 拓扑证明 app 只连 :22、跳板转发 :2223** = 真 ProxyJump。SPEC §11 多跳 cell 回填。**这是 iOS 纯模拟器能验的最后一块——iOS 客户端核心(列表+状态+SSH+健壮+多跳)收官。**

**✅ ssh-rsa 跨端坑已解**:真实 host(`xreal_TK-ALIYUN`/`xreal_OPS`/dev-rig `xreal_phase0`)2026-05-31 核实**全是 ed25519**,无需迁移;**约定客户端一律 ed25519、不用 RSA**(Citadel RSA 走 legacy ssh-rsa/SHA-1)。SPEC §5。

**✅ 服务端 maestro 开机自启(2026-05-31,commit `0bd34bd`,已部署 TK)**:`xreal-project.sh` 加 `restore`(按 manifest 幂等重建整个 deck)+ `install-autostart`(@reboot cron,免 root)。**TK 已部署**:scp 新脚本 + 装 @reboot cron + `restore` 把 company-web/invest-digest 拉回(4 session 全活;swap/openvpn 重启本就自动回来)。⚠️ project 的 claude 走 manifest `startup="claude"` = **重启后开全新会话**(maestro 是 `--continue` 续);要 project 也续上下文,把它们 manifest `startup` 改 `claude --continue`。

**✅ iOS 已上真机(iPhone 15 Plus / iOS 18.5),功能闭环**(2026-05-31):
- **Phase 5**(`bc5c746`)真机签名装机 + **配置注入**(SPEC §8 唯一待解已解):分享单「Open in」自含 `.xrhosts`(内联 key)→ 导入私有存储。真机实测 AirDrop→导入→SSH 连 Mac LAN host。
- **Phase 6**(`8765af1`)**同款 logo**(从 `docs/images/icon.svg` 渲染,跟 Android 一个 `>_`)+ `importConfig` **三类导入**(单 host 追加 / 全局替换 / ASR 凭证,按文件顶层内容判别,AirDrop 文件也吃)。**⚠️ app 内「齿轮→host 配置页文档选择器」入口本做了又撤回 → P2**(用户决策:这版只 AirDrop,与「无设置 UI / agent 代劳」哲学一致;config 页代码删了,git `8765af1` 有)。
- **全屏沉浸 + IME 抑制**:`prefersStatusBarHidden`/`prefersHomeIndicatorAutoHidden` + Info.plist `UIStatusBarHidden`(隐藏状态栏=AR 眼镜真全屏);终端禁系统软键盘见上(swizzle)。
- **终端禁系统 IME**:swizzle `WKContentView._requiresKeyboardWhenFirstResponder=false`(压软键盘)+ `inputAccessoryView=nil`(压工具条)= Android `FLAG_ALT_FOCUSABLE_IM`。真机验过。
- **签名**:免费 Apple ID(`zyayhj.yhj@163.com`),team ID 在 **gitignored `ios/Signing.xcconfig`**(不进公开 repo);**证书 7 天到期要重签**(`xcodebuild -allowProvisioningUpdates` 重装)。
- **真机截图能力**:`pymobiledevice3`(已装 ~/.local/bin)+ 用户起的 `sudo pymobiledevice3 remote tunneld` 隧道 → 我能 `developer dvt screenshot` 独立看真机屏。

**➡️ 下一步(仍需硬件/用户在场)**:
- **✅ 语音已真机验通**(端到端:麦克风→豆包流式 ASR→PREVIEW→Enter 注入 SSH,🎤 前缀,中文识别 + CJK 字体正常)。从 Android port 全套:`VolcFrame`/`VolcAsr`(URLSessionWebSocketTask,凭证读导入的 asr.json)/`AudioCapture`(AVAudioEngine 16k/mono)/`VoiceController`(状态机)/`Hotwords`;`Bridge.voiceDown/voiceUp`;index.html 语音键/overlay 共享未改。**修过两个真机 bug**:① `VolcFrame.parse` 数组越界崩溃 —— 火山 v3 协议**事件帧 flags=4(WithEvent bit2)** 被当 size 读越界,加边界保护安全 ignore(结果帧 flags=0/1/3 正常解析);② **首次 voiceDown 录空** —— `AudioCapture()` 原建在异步权限回调里、比同步 voiceDown 晚,改成 `setupVoice` 同步建。豆包凭证从 `.env`(`APP_ID`/`Access_Token`)→ `.xrhosts` asr 导入。豆包 WS 海外端点可用(本次没撞 GFW;参 SPEC §5.1 用户并行做的 xray-over-443)。
  - 残留小事:火山事件帧现"安全 ignore"+ 打 hex 日志(可后续显式跳过 WithEvent 帧,不必须)。
- **F1/F2 物理键路由**:8BitDo→GameController(hold-to-talk 语音 / F2 返回;**列表页 F2→host 配置页**那条语义随 host 配置页一起搁 P2);翻页。
- **AR 眼镜**:iPhone 15+ USB-C DP 直连 XREAL One Pro(用户接)。
- disconnect→vkey 恢复(真机验)。
>
> **commit 节奏(用户 2026-05-31 定)**:iOS 分阶段建,**每个截图验证过的 phase 直接 commit(不 push)**,不再逐个问。见 memory [[phase-build-autocommit]]。

> ⚠️ commit 状态:release `d0bbb4c` 已推送;契约层 `256871a` + POC `3259ae4` 已 commit(本地未 push);**Phase 1(`ios/` + 共享 `index.html` + SPEC §5/§6.1 + 本 HANDOFF)本次 commit**。`android/` 仅共享 `index.html` 被动(其它一字未动)。

---

项目**早已过 Phase 0**。核心端到端闭环 + Agent 状态展示已在 **Beam Pro X4100 真机**跑通,两台真实 host 在日常用:

- **TK-ALIYUN**(海外 Aliyun,直连)+ **OPS**(AWS 内网,只 VPN 可达,`via = "TK-ALIYUN"` 经 TK 多跳)。各跑一个 Maestro。
- **OpenVPN 从手机搬到 TK**:手机不再挂 VPN,OPS 经 TK 的 OpenVPN + ProxyJump 端到端认证可达(见下方多跳 SSH 条)。

**本轮(2026-05-31)落地**(均真机验证,详见 §1):
- **多跳 SSH(ProxyJump)**:`HostConfig.via` + `SshJump`(sshj 本地端口转发),OPS via TK 端到端认证。
- **Agent 状态展示**:卡片显示 working / waiting / disconnected / unknown + 时长。**走 Claude Code hooks 事件驱动,非抓屏**:hook 写 `<base>/.xreal/status.json`,app 进列表/back/onStart 各 `cat` 一次(`ManifestFetcher` 顺手拉),`xreal-project.sh` 自动部署 hooks。增量渲染防闪烁。
- **持久化日志 + 崩溃捕获**:`AppLog` 写外存(adb pull 不需 run-as)+ `XrealApp` 全局未捕获异常处理器。
- **tmux 半页翻页**:Shift+↑/↓ → root 表进 copy-mode(不与 Claude Code 冲突)+ history-limit 50000(`-f conf` 注入,服务端零增量)。
- **虚拟键盘动态显隐**(8BitDo 插拔实时切)+ **列表首屏加载态**(状态徽章位冷加载转圈)。

**状态展示的 hooks vs 老抓屏路径(下个 cold-start 必看,别搞混)**:
- 现在的实时状态来自 **hooks → status.json**(事件驱动)。`status.json` schema = `{session, state, since}`,**只有 state + 时长,没有 preview(最近命令)文本**。
- 老的 `StatusPoller`/`AgentStatusDetector` 抓屏轮询(`tmux capture-pane` 解析)**已被取代、仍 dormant**:`FleetFeatures.LIVE_STATUS` 仍是 `false`,代码留着但不是状态来源。
- **⚠️ 别再让下个 session 去 `LIVE_STATUS=true`**——那是已死路径,翻它没用。状态由 hooks 提供。ROADMAP §4 老的"接回清单"已据此标注作废。
- 仍**未做**:列表卡片的 **preview 文本(最近命令预览)**——它需要抓屏,随老路径一起搁置(见 ROADMAP P2.2)。

---

## 0. (历史)最新进展(2026-05-28 晚 · 产品重塑 + UI 打磨,均真机验证)

产品从"单 SSH 终端"重塑成 **AI agent 集群指挥台 "Agent Deck"**(详见 memory `product-vision`)。主入口 = WebView SPA 列表页 ⇄ 终端页。已在 **Beam Pro X4100 真机**全部验证通过:

- **Agent Deck 列表页**(`index.html`):host 分组、Claude/SSH/agent 三类 icon、工作中/等待反馈/未激活/断开 四态色(等待反馈琥珀脉冲最跳眼)、agent 最近命令 preview、顶部舰队概览。**(2026-05-31 更新)四态色现由 hooks 状态(status.json)驱动,已落地;最近命令 preview 仍待抓屏路径(见 §0.0)。**
- **横屏锁定 + 响应式**(`auto-fill minmax(360px)` 双/三列,适配眼镜 16:10)。
- **彻底禁用系统 IME**(`FLAG_ALT_FOCUSABLE_IM`)+ **自绘虚拟键盘 v2**(13 键 2 行,只在终端显示;列表卡片可点导航)。
- **SPA 导航**:DPAD_CENTER 进项目,⌂返回/硬件BACK 回列表(键盘专用:已去掉卡片点击 + 终端 ‹返回 触摸按钮)。
- **虚拟键盘 v3**(在 v2 之后):一行 13 键,列表+终端**共用**(列表态淡化终端专用键),固定高度;overlay 改 `position:absolute` 锚内容区,永不压键盘。

**状态探测 pipeline 落地 + 真机端到端验证 + detector 已校准(2026-05-28/29,task 0.3)**:
- 代码:`AgentModels`(Host→Project 模型 + Status enum)、`AgentStatusDetector`(纯函数启发式 parser)、`HostClient`(per-host 单次 exec 批量 `tmux capture-pane`,`===session===` 分隔)、`StatusPoller`(协程轮询→序列化→`window.setHosts` 推 WebView)、`Crypto`(BC provider 修复)。
- **✅ detector 已对 Claude Code v2.1.153 实测校准**:真快照存 `app/src/test/resources/panes/`(idle/working/waiting/ssh),`ClaudeCodePaneCalibrationTest` 锁 4 状态分类。**13 个单测全过**。关键结论:WORKING 靠 `esc to interrupt`(spinner 词随机:Osmosing/Hashing/Mulling/Doing);WAITING 靠 `Do you want to proceed?`+`❯ 1.`;`✻` 既在 spinner 也在完成行。
- **✅ 真机端到端跑通(0.3)**:Beam Pro 经 `adb reverse tcp:2222 tcp:22` → Mac sshd → sshj → tmux capture → detector → 列表 UI。实测 IDLE→WORKING 实时翻成「工作中」绿色,fleet 计数同步。
- **0.3 路上修的两个真 bug(都已修,是 keeper)**:① sshj 在 Android 报 `no such algorithm: X25519 for provider BC` —— Android 自带精简 BC 遮蔽完整 bcprov;`Crypto.ensureFullBouncyCastle()`(MainActivity.onCreate 首行调)移除系统 BC 插完整版修复。**这同时干掉了 Stage A.2 的主要风险**。② 非交互 SSH exec 的 PATH 太窄找不到 tmux → HostClient 脚本前置 `export PATH=...:/usr/local/bin:...`。
- **怎么重跑这个 demo**(loadHosts 现返回 `emptyList()`,poller 默认休眠):① Mac 起 tmux session + `claude`;② `adb reverse tcp:2222 tcp:22`;③ `adb push ~/.ssh/xreal_phase0 /data/local/tmp/`;④ 临时把 `SettingsStore.loadHosts()` 改成读 `/data/local/tmp/xreal_phase0` + 返回 mac-dev host(见 git `bfa83f0..` 之后那次 0.3 commit 的 diff 里有现成代码)。**测完改回 emptyList()**。

**✅ per-project 真 SSH 终端落地 + 真机端到端(T.1)**:
- `onOpenProject` 查 `hosts` 配置 → 后台连 `SshConnection`(`tmux new -A -s <session>` attach 该 project)→ `switchTo` 热切活动 channel;查不到(mock)→ 回退 `LocalEchoChannel`。`switchTo` 用 reader generation + 关旧 channel 解阻塞;`openSeq` 防快速 open→back→open 错绑(advisor 抓的 race)。
- **真机实测**:Beam Pro 列表 → 开 proj-claude → SSH attach 真 tmux → **活的 Claude Code v2.1.153 渲染进 xterm**;打字流回 Claude(它开始 working);BACK → 列表,SSH 断开但 **tmux session 持久存活**(Claude 后台继续)。完整生命周期通。
- **修的 bug**:热切后 PTY 停在初始 80x24 → tmux 内容画不满。因为 `showTerminal` 的 fit→onResize 早在 SSH 连上前就触发(打到 LocalEcho)。修法:`switchTo` 后调 `window.syncSize()` 把当前 xterm 尺寸重推给新通道(实测 client 变 94x11,内容填满)。

- git:`8599d2c` 脚手架 → `e8260a5` 产品重塑 → `94a321d` 键盘 v2 → `4ca6637` 键盘 v3 → `bfa83f0` 状态探测 pipeline → `4e11c1b` 0.3+BC/PATH+校准 →(per-project SSH 终端 这次 commit)。

**✅ 真 host 持久化 + 电脑打字直通手机终端(R.1-3,测试工具)**:
- `loadHosts()` 现读 `/data/local/tmp/xreal_hosts.json`(过渡持久化,无录入 UI 期间;无文件→空→mock)。schema 见 SettingsStore。`readPemSafe` 校验 keyPath 防路径遍历。
- `DebugInputServer`:**debug build + hosts.json 存在**才监听 `127.0.0.1:8889`,把裸字节写进活动 channel(= 在手机上敲键)。
- `scripts/setup-mac-host.sh`(幂等搭 host:tmux+claude、adb reverse/forward、push key+hosts.json、重启 app)+ `scripts/term-relay.py`(raw 键盘→socket→手机终端)。命令见 CLAUDE.md §10.6。
- **真机实测**:`setup-mac-host.sh` → 列表出现真 host `mac`(claude-main/shell)→ 开 claude-main → 电脑 `printf 'echo X' | nc :8889` → 文字实时出现在手机 Claude 输入框。整条 Mac→手机打字链路通。
- **坑(已修)**:push 的 key 必须 `chmod 644`,600 会让 app uid 读不到(EACCES)→ loadHosts 静默返回空 → poller/relay 都不起。

**✅ 终端中文 + powerline 显示修复(D.1,真机验证)** —— 一场长 debug,根因藏得深:
- **根因:tmux 客户端没在 UTF-8 模式**(`utf8=0`),把所有多字节(中文 + powerline 字形)在**远端就降级成 `_`** —— 字节根本没以 UTF-8 到达 app(十六进制 log 显示 `中` 进来是 `5f`=下划线,不是 `e4b8ad`)。**修:`tmux -u` + `export LANG/LC_ALL=*.UTF-8`**(见 MainActivity.tmuxAttachCommand / HostClient / setup-mac-host.sh)。tmux server 也必须在 UTF-8 locale 下创建。
- **字体(WebGL,与 VS Code 终端同款)**:Meslo LG S(用户 iTerm 同款,Latin+powerline,`meslo-powerline.otf`)主字体 + Sarasa Term SC Nerd 子集(`sarasa-term.ttf`,7.95MB,CJK 2:1)回退。
- **xterm WebGL 两个真机坑(都修了)**:① **字体异步加载完再创建终端**(`fontReady.then(initTerm)`),否则字形图集建在空字体态 → 空白(clearTextureAtlas 救不回);② 容器须可见时 open(惰性建在首次 showTerminal)。`allowFileAccessFromFileURLs=true` 让 file:// @font-face 能加载。
- **方法论教训**:别靠截图猜,在数据链路上打**十六进制 log** 一步分清"远端字节问题 vs 前端渲染问题"。我前期陷入"每轮换一个变量"的失控循环,被 WebGL 带偏,其实是 locale。

- git:… → `4e11c1b` 0.3+BC/校准 → `994199e` per-project SSH 终端 →(真 host+打字直通 R.1-3 + 字体/locale 修复 D.1 这次 commit)。

**仍 mock / 待接(默认无配置时)**:没 push hosts.json 时列表走 index.html mock;host 录入 **UI** 仍缺(现靠 adb push hosts.json);真豆包 ASR 待 creds。中文回退用 Sarasa(用户 iTerm 的 PingFang 是 Apple 专有打不了包)。`fonttest.html` 留作字体诊断工具。

---

## 1. (历史)Phase 0 + Stage B 代码完成

Phase 0(emulator 跑通骨架)+ Stage B(真 SSH / 真 AudioRecord / 真豆包 ASR client)的代码全部写完,APK 编译通过。

**没跑过的事**:
- Emulator 端到端演示(本机内存压力 ~328 MB unused / 需要 5 GB,emulator 启时 QEMU CPU 线程一律 exit 139)
- 真 SSH 连通验证(user 还没开 Mac sshd / 装 abduco / 给 SSH key)
- ~~真 8BitDo F13/F14 keycode~~ → ✅ 已实测(2026-05-29):F13/F14 在 Beam Pro 到不了 app(Generic.kl 注释),改用 **F1/F2**,真机验证通过
- 真豆包 ASR(user 没给 appid/token,且 endpoint 路径要按 Volcengine console 微调)

---

## 2. 代码结构(Phase 0 + Stage B 完成后)

```
android/app/src/main/
├── AndroidManifest.xml         INTERNET / RECORD_AUDIO / FOREGROUND_SERVICE_MICROPHONE
├── assets/
│   ├── index.html              WebView SPA:Agent Deck 列表页 ⇄ 终端页 + xterm.js + voice overlay + 自绘虚拟键盘
│   ├── xterm.{js,css}          v5.5.0
│   ├── addon-{fit,webgl,search}.js
├── res/values/
│   ├── strings.xml             所有 user-facing 文案
│   └── themes.xml              全屏黑底
└── kotlin/io/github/kevinfitzroy/xrealclient/
    ├── MainActivity.kt         WebView + 路由 + lifecycle(247 行)
    ├── ConfigActivity.kt       首次启动配置 UI(programmatic,150 行)
    ├── SettingsStore.kt        SshConfig / AsrConfig + SharedPreferences
    ├── PtyChannel.kt           抽象接口
    │   ├── SshConnection.kt    sshj 实现(默认 abduco 启动命令)
    │   └── LocalEchoChannel.kt 测试/降级实现
    ├── TerminalBridge.kt       @JavascriptInterface,Base64 桥
    ├── VoiceDaemon.kt          状态机 + overlay + Asr 调用
    │   ├── AudioRecorder.kt    16kHz mono PCM_16BIT + WAV 头
    │   ├── Asr (interface)
    │   ├── MockAsr             固定串("ls -la\n" / "pwd\n")
    │   └── VolcEngineAsr.kt    豆包 REST 客户端(端点见 §3 注意事项)
```

---

## 3. 几个跟 CLAUDE.md / architecture.md 不一致的取舍(都记录)

| 项 | spec | 实际 | 原因 / 何时改 |
|---|---|---|---|
| `compileSdk` / `targetSdk` | 35 | 34 | user 机器只装了 android-34 platform,无 cmdline-tools 自动装。Phase 1 升 |
| `androidx.core:core-ktx` | 1.15.0 | 1.13.1 | 上面 compileSdk=34 的连带后果 |
| AVD | Pixel_7_Pro_API_34 | Pixel_8a(target android-37,arm64-v8a,`ai_glasses_compatible` tag) | user 已存在;但启不起来(见 §4) |
| host key verifier | OpenSSHKnownHosts | **TofuKnownHosts**(filesDir/known_hosts;首次见 host 自动加,key 变 fail loud)| Phase 1 真机时改成弹 dialog 让 user 对照 fingerprint |
| SSH key 存储 | EncryptedSharedPreferences | 明文 SharedPreferences + 写 filesDir/ssh_key | Phase 2 加密 |
| Voice 录音 service | Foreground Service(MICROPHONE) | Activity-bound AudioRecord | Phase 1 后台录音再补 service |

---

## 4. (历史 · 已不相关)Emulator 启不起来 — 已知症结

> **2026-05-31 注**:早期 Phase 0 时本机内存压力起不了 emulator 的症结。**现在主战场是 Beam Pro X4100 真机**(adb 直连),emulator 不再是验证路径。这段留作历史,日常调试看 CLAUDE.md §10 + `scripts/setup-mac-host.sh`。

Mac M1 Pro / macOS 26.3.1 / 16 GB RAM,但 `vm_stat` 显示 **unused 仅 328 MB**(15 GB 全被占,5.9 GB 已进 memory compressor)。Emulator 启动需要 5 GB,QEMU CPU 线程拿不到页面卡死 exit 139。三次尝试:
1. `-gpu auto` — 段错误
2. `-gpu host` — 段错误
3. `-no-snapshot -no-accel -no-boot-anim` — 段错误,日志明示 `Software GL rendering due to system memory pressure (Available 2494 MB, Required 5120 MB)`

**解锁路径**:user 关掉 Chrome / 大 Electron app 或重启 Mac,unused 至少 5+ GB,再试 `$HOME/Library/Android/sdk/emulator/emulator -avd Pixel_8a -no-snapshot -gpu host &`。如果 Pixel_8a(android-37 preview)仍有 VulkanVirtualQueue 警告(emulator 36.5.11.0 太老),让 user 在 AS Device Manager 建 vanilla Pixel 7 Pro API 34 AVD。

---

## 5. (历史)早期 Phase 0 的"准备工作"清单

> **2026-05-31 注**:下表是 Phase 0 时的待办,**绝大部分早已完成**:真机(Beam Pro X4100)在用、真 SSH 双 host 在用、8BitDo F1/F2 已实测、真豆包 ASR 已接(P1.2 ✅)。仍未启用的只有真机 emulator(已不走这条路)。当前真实进度看 §0.0。

| 任务 | 触发条件 | 阻塞什么 |
|---|---|---|
| 释放内存 / 重启 Mac | 想跑 emulator 看效果 | 0.8 + 任何 UI 验证 |
| Mac 开 Remote Login + brew install abduco + 生成 SSH key | 想跑真 SSH 链路 | 真 SSH 验证 |
| 火山引擎 ASR appid / token | 想跑真 ASR | 真豆包识别;mock 模式不受影响 |
| Android 14 真机(任意,USB) | Phase 1 | 8BitDo / 真麦克风 / sshj BC 兼容 |
| 8BitDo Micro 实物 | Stage A.1 | F13/F14 keycode 验证 |
| Beam Pro 实物 | Phase 2 | AR 眼镜实际体验 |
| git remote | 想 push 备份 / 分享 | 仅本地 commit 时无 |

---

## 6. 新 session 的第一步

主战场是 **Beam Pro X4100 真机**(adb 直连),不走 emulator。日常构建/装机/取证命令统一在 CLAUDE.md §10。

### 跑一遍真机(本机当测试 host)
`./scripts/setup-mac-host.sh`(幂等:起 tmux+claude、adb reverse/forward、push key+hosts.json、重启 app)→ 列表出现真 host → 开 project → 真 SSH 终端。电脑打字直通:`python3 scripts/term-relay.py`。详见 CLAUDE.md §10.6。

### host 接入 = 代客安装(Valet),无设置 UI
真 host(TK-ALIYUN / OPS)经 Valet agent `adb push` key+config 到 staging,app 启动 `SettingsStore.importStagingIfPresent` 导入私有存储。**刻意不做 host 录入 UI**(老的 `ConfigActivity` 已被取代)。引导见 `docs/agent-setup-guide.md`。project 级清单由各 host 的 Maestro 写 manifest(`<base>/.xreal/projects.json`),app `cat` 拉取。

### 状态展示部署
hooks 由 `docs/xreal-project.sh` 自动部署(写 `<base>/.xreal/status.json`)。新 host 上的 Maestro 起 project 时会带上,app 进列表即读。

### 真机取证(出问题时)
持久日志在外存,`adb pull` 取(`AppLog`,不需 run-as)。崩溃也落盘(`XrealApp` 全局 handler)。具体路径见 CLAUDE.md §10 日志取证。

### 物理设备实验(若回头补)
docs/stage-a-experiments.md:A.1 8BitDo(已实测改用 F1/F2)、A.2 sshj BC(已随 §1 R 修复)、A.3 WebView 60fps。

---

## 7. 关键注意事项(避免新 session 踩坑)

- **真机优先** — 主战场是 Beam Pro X4100(adb 直连),emulator 已不是验证路径(早期内存压力起不来,见 §4 历史)
- **不要去 push `clawzhang89-bot/term-on-demand`** — 那是上游设计文档仓库
- **不要重新讨论架构** — 经过 5+ 轮 review;CLAUDE.md §5 的 7 条都有理由
- **包名 `io.github.kevinfitzroy.xrealclient`** — 个人项目,不是 zklink(zklink 是 user 邮箱域名,跟项目无关)
- **JAVA_HOME 必须显式指向 JBR 21** — 系统 java 是 Java 8 跑不了 AGP 8.7。CLAUDE.md §10.1 有命令
- **commit 用 kevinfitzroy 身份**(CLAUDE.md §8),Phase 0/B 默认全本地不 push

---

## 8. Phase 0 / Stage B 完成时的实际产出清单

✅ 1064 行 Kotlin + 1 HTML(290 行) + Manifest + strings 资源
✅ `./gradlew assembleDebug` BUILD SUCCESSFUL,APK 14 MB
✅ 抽象接口 `PtyChannel` + `Asr` — 干净的 sshlib/Whisper fallback 替换点
✅ 真 AudioRecord(16kHz mono PCM_16BIT,WAV 包装)
✅ 真豆包 ASR REST 客户端骨架(等 user creds + endpoint 微调)
✅ SharedPreferences 配置持久化 + ConfigActivity 录入 UI
✅ 运行时 RECORD_AUDIO 权限请求
✅ Ctrl+Alt+1/2 作为 F13/F14 备路径
✅ 失败回退:SSH 挂了 fallback LocalEchoChannel + Toast,UI 不卡死

❌ Emulator install + 端到端跑(等 user 释放内存)
❌ 真 SSH 连通(等 user 开 sshd / 装 abduco / 给 key)
❌ 真豆包 ASR 调用(等 user 给 creds + 可能微调 endpoint)
❌ EncryptedSharedPreferences(Phase 2 加)
❌ Voice Foreground Service(Phase 1 加,目前 Activity-bound)
❌ TOFU dialog 化(目前自动 trust;Phase 1 改成弹 fingerprint dialog)
❌ Stage A 真机三实验(F13/F14、sshj BC、WebView 60fps)— 物理设备到位后

---

## 9. 这份 HANDOFF.md 何时更新

- **每次一组功能落地(真机验证过)** → 在 §0.0 顶部加本轮要点 + 更新 header「最近更新」日期,把上一轮要点下沉成历史
- 新 host / 新 host 接入方式变化 → 更新 §0.0 host 列表 + §6
- ROADMAP 某条状态翻转(⬜→✅ 或搁置→实现) → 同步 ROADMAP **再**在 §0.0 提一句
- 任何 fallback 路径触发(如 sshj → sshlib swap) → 在 §3 表里记
- 老段落只要还描述"当前世界"且已过时 → 打 `(历史)` 标,别留着误导下个 cold-start
