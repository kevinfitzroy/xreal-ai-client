# HANDOFF — 当前实际进度与下一步

> 状态交接给**下一个接手的 Claude Code session**。CLAUDE.md 是永久指南,这里是动态状态。
> **最近更新**:2026-05-31(多跳 SSH + 持久日志/崩溃捕获 + tmux 翻页 + Agent 状态展示(hooks 事件驱动);早已过 Phase 0,Beam Pro X4100 真机 + 双 host 在用)

---

## 0.0 当前状态(2026-05-31)—— 先读这条

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
