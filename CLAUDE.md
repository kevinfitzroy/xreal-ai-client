# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

# XREAL AI Client — Claude Code 项目指南

> **你正在加载一个 cold-start session**。这份文档让你立即知道:你是谁、要做什么、为什么、关键约束、协作偏好。读完这份之后,根据需要去 `docs/` 看更深的内容。

---

## 1. 你的角色

你是这个项目的**实施 agent**。

**任务**:实现一个 Android App,把 SSH client + 终端 UI + 语音输入全部塞进同一个进程,跑在 XREAL AR 眼镜 + Beam Pro 上,让用户通过物理按键 + 语音操作远程服务器上的 Claude Code(及 Maestro 编排的 agent 集群)。

**当前状态**:**已在真机 Beam Pro X4100(Android 14)上部署运行,核心闭环全打通**——项目列表 → 开 project → 真 SSH 终端 → 物理键盘/语音 → 返回列表。两台生产 host 在用(脱敏名):**jump-edge**(海外)、**private-worker**(内网,经 jump-edge 多跳 ProxyJump 到达),各跑 Maestro 编排。

最近一轮(2026-05)已落地:多跳 SSH(`via` + SshJump,手机不挂 VPN)、持久化日志 + 崩溃捕获(AppLog/XrealApp)、tmux 半页翻页(Shift+↑/↓)、虚拟键盘动态显隐、列表冷加载态、Agent 状态展示(working/waiting/disconnected/unknown,走 Claude Code hooks,见 §6)、**SSH-over-443 隧道**(可选 per-host:app 内嵌 xray-core 起本地 dokodemo-door,SSH 经 vmess|vless/tls:443 绕 GFW 对 :22 的限速;**vmess + vless(Reality);vless iOS 先行,Android 待跟**;见 §5.1 + SPEC §5.1)。

**你的任务是在这套已运行的真机系统上继续迭代**(改 bug、加能力),不是从零搭脚手架。

**你做不了、需要用户协助的事**(无物理设备无法验):8BitDo 物理按键真机端到端、真麦克风录音、Beam Pro 特定的 NebulaOS 后台/GPU/AR 显示行为。

---

## 2. 为什么这个 App 存在(超浓缩背景)

完整背景见 [`docs/background.md`](docs/background.md)。一段话:

用户在通勤 / 咖啡馆 / 公园这种场景下,想用 XREAL One Pro AR 眼镜 + Beam Pro(口袋大小的安卓主机)做远程服务器开发,主要交互方式是**物理小键盘(8BitDo Micro,~6 键)+ 中英语音**(因为 AR 眼镜下鼠标/触摸不方便)。他需要一个 SSH client,但 Termius/Termux 等现成 client 在这个场景下有两个核心痛点:

1. **UI 太老**(Termux)或**不可控**(Termius 闭源),不适合 AR 眼镜下大字号 / 高对比度 / 现代视觉
2. **跨 App 注入语音文本到 SSH 输入区**在 Android 安全模型下非常难(SYSTEM_ALERT_WINDOW 不能跨 App,Accessibility 体验差,IME 与硬件键盘冲突)

经过多轮架构迭代(详见 upstream 仓库的 `docs/06`、`docs/07`),最终方案是**一个 Android App,WebView 跑 xterm.js 当漂亮 terminal UI,Kotlin 用 sshj 直连云端 SSH,同 app 内一个 Voice Daemon 录音→豆包 ASR→直接写 SSH outputStream。服务端零增量,只跑用户已有的 tmux + Claude Code**。

整套思路是 [`term-on-demand`](https://github.com/clawzhang89-bot/term-on-demand) 这个上游项目的"终端优先 + 按需 UI" 哲学的具体实施。

---

## 3. 整体架构(必读)

```
┌─ Beam Pro 上的一个 APK ──────────────────────────────────┐
│                                                          │
│  WebView(xterm.js + WebGL + 自定义 CSS) ← UI 层        │
│       ↑ JS:term.write(b64)   ↓ JS:onData(b64)          │
│       │                       │                          │
│  JSBridge(Base64 over evaluateJavascript)               │
│       ↑                       ↓                          │
│  SSH 模块(sshj 0.39+) — TCP → SSH → PTY                │
│       ↑                                                  │
│  Voice Daemon(Foreground Service)                       │
│  ├─ dispatchKeyEvent 路由 F1/F2 (8BitDo 物理键)          │
│  ├─ AudioRecord → Opus → 豆包 ASR                       │
│  ├─ WebView.evaluateJavascript("showOverlay(...)")       │
│  └─ Enter 确认 → sshSession.outputStream.write(text)    │
│                                                          │
└────────────────┬─────────────────────────────────────────┘
                 │ Raw SSH (port 22)，内网 host 经跳板机 ProxyJump
                 ▼
       多台 host(jump-edge 直连 / private-worker 经 jump-edge 多跳)
       └─ tmux: 每 host 一个 Maestro + N 个 project session
          claude / agent / ssh,Maestro 编排;hooks 写 .xreal/status.json
       (无 ttyd / 无 nginx / 无 Voice Gateway;唯一服务端增量见 §5)
```

详细版含可编译代码骨架:[`docs/architecture.md`](docs/architecture.md)。

> **客户端契约(平台中立)= [`SPEC.md`](SPEC.md)**。host/project 列表怎么来、状态怎么算、语音怎么注入、按键什么语义、配置什么形状 —— 这些跨端行为的单一真相源在那。当前 Android 已实现,iOS 客户端规划中(见 [`HANDOFF.md`](HANDOFF.md))。**改任何跨端行为先改 SPEC.md,再两端对齐**;上图的 `Foreground Service`/`AudioRecord`/sshj 等是 Android 平台落点(SPEC §11 矩阵),不是契约本身。

---

## 4. 已建成的系统组件(代码地图)

脚手架 + 核心闭环早已完成,真机在跑。下面是主要模块,改东西前先定位:

- **SSH 层**:`SshConnection`(connect/auth/PTY/shell/resize/disconnect)、`SshJump`(多跳 ProxyJump,sshj 本地端口转发)、`PtyChannel`、`TofuKnownHosts`(TOFU known_hosts)
- **终端 UI**:`assets/terminal.html`(xterm.js + WebGL + unicode11 addon + overlay div)、`TerminalBridge`(`@JavascriptInterface` + Base64 双向桥)、`LocalEchoChannel`
- **语音**:`VoiceDaemon`(状态机)、`AudioRecorder`、`VolcEngineAsr` / `VolcFrame`(豆包流式 ASR)、`Hotwords`(项目级热词)
- **列表 / 编排**:`MainActivity`(项目列表 + 终端 + 物理键路由 + tmux conf 注入)、`ManifestFetcher` / `HostClient`(读 host manifest)、`AgentModels`(HostConfig 带 `via`)、`StatusPoller` + `AgentModels`(Agent 状态:hooks→status.json 一次性 cat)
- **SSH-over-443 隧道(VPN/翻墙,可选)**:`XrayProxy`(内嵌 xray-core 起本地 **dokodemo-door**、override→服务端 `127.0.0.1:22`,返回本地口给 sshj **直连**;**反射调** `xraybridge.aar`,aar 缺失即优雅降级)、`XrayConfig`(vmess:// 解析 + 生成 xray JSON,纯函数,有单测 `XrayConfigTest`)、`AgentModels` 的 `ProxyConfig`(host 内联 `{name,localPort,url}`)+ `effectiveProxy(all)` 归属 resolver + `localPortConflict` fail-closed 校验(单测 `ProxyResolveTest`)。SSH 消费方**三类**(`SshConnection` 终端 / `SshJump` 跳板外层 / `HostClient` 状态/manifest 轮询);解析并注入 `effectiveProxy` 的**调用点四处**(`MainActivity`/`ManifestFetcher`/`StatusPoller`/`SshJump`)——漏一个就绕过隧道在 :22 hang。Go 侧封装在 **`xray-bridge/`**(根目录,非 android/):`bridge.go`(封官方 xtls/xray-core,`core.StartInstance("json")`、无 tun)+ `build.sh`(gomobile bind → `android/app/libs/xraybridge.aar`)。详见 §5.1 + SPEC §5.1。**Android 当前只 vmess;iOS 已加 vless(Reality)** —— iOS `XrayConfig` 有 `parseVless`(URLComponents 解析明文 URI)+ `buildVless`(reality outbound)+ `makeConfig` 统一分派,Android 对称跟进只需在 `XrayConfig.parseVmess` 旁加 `parseVless`。⚠️ gomobile xray 内部 DNS 会超时 → `XrayProxy` 用系统 resolver 把节点域名解析成 IP 传 `XrayConfig`(SNI 仍域名)。
- **基础设施**:`XrealApp`(全局未捕获异常 + 生命周期/网络/display 监控)、`AppLog`(外存文件日志,`adb pull`)、`SettingsStore` / `ConfigActivity` / `Crypto`、`DebugInputServer`(debug 期电脑直通终端)
- **搁置**:`AgentStatusDetector`(抓屏检测)+ `FleetFeatures.LIVE_STATUS`(实时刷新,P2,默认关)——状态展示现在走 hooks,**不是**这套

服务端侧:`docs/xreal-project.sh`(Maestro 建/进 project + 自动部署状态 hooks)、`docs/orchestrator-CLAUDE.md`(host 上 Maestro 的指南)、`docs/agent-setup-guide.md`(host 接入步骤)。

---

## 5. 关键约束(不要 deviate)

这些都是经过 4-5 轮架构 review 收敛下来的决策,**不要重新挑战**。如果你觉得某条需要调整,先告诉用户,等批准再动。

| 约束 | 解释 |
|---|---|
| **零服务端增量(一个例外)** | 不要引入 ttyd / nginx / 任何云端 Voice Gateway / tmux-send-keys daemon。服务端只跑用户已有的 tmux + Claude Code。**唯一用户显式授权的例外**:每个 host 的 maestro 目录(`.xreal/`)放 `agent-status.sh` + Claude Code hooks,事件驱动写 `.xreal/status.json` 供 app cat(状态展示用,非抓屏)。除此之外仍守零增量 |
| **单 App 闭环** | 不要做"主 app + 辅助 service"双进程架构。所有逻辑在一个 APK 内 |
| **Overlay = WebView 内 HTML** | 不要用 `SYSTEM_ALERT_WINDOW` 权限。Voice 预览 overlay 就是 WebView 里的 `<div>`,通过 JSBridge show/hide |
| **Voice → SSH 直写** | Voice Daemon 拿到 ASR 文本,**直接写 ssh.outputStream**,字符走 SSH 到远端 shell,shell echo 回送,xterm.js 渲染。Voice 路径不需要知道 xterm.js 存在 |
| **不用 Accessibility / IME** | 不需要这两个权限。同 app 内事件路由用 `Activity.dispatchKeyEvent` |
| **F1/F2 物理键主路径**(2026-05-29 Stage A.1 实测改定) | 原设计 F13/F14(326/327),但 Beam Pro 的 8BitDo 走 `/system/usr/keylayout/Generic.kl`,其中 F13–F24 全被注释 → keycode 映射不出、到不了 app。改用 **F1=语音(hold-to-talk)、F2=返回列表**(F1–F12 在 Generic.kl 活跃);Ctrl+Alt+1/2 备路径保留,F13/F14 代码分支留作其它设备兜底。详见 README「操作」章节 + memory `beam-pro-device` |
| **session 驻留:agent 用 tmux,纯 SSH 可 abduco**(2026-05-28 修订)| 原决策是默认 abduco(单终端场景,client 自己管 scrollback)。但产品升级成"AI agent 集群指挥台"后,**状态探测 + 最近命令预览需要 `tmux capture-pane -p`,abduco 无等价能力** → agent 类 project 改用 tmux。纯 SSH project 不需要探测,abduco/tmux 均可。`SshConnection` 启动命令本就可配置。详见 [`docs/session-persistence-options.md`](docs/session-persistence-options.md) 和 memory `product-vision` |
| **优雅降级** | 任何组件挂了,用户能退回 Termius / Termux 继续工作。App 不是必需品 |
| **SSH-over-443 = 客户端侧翻墙,不破零增量**(2026-06-01) | GFW 卡 :22 时,host 配 `proxy`(vmess)→ app **内嵌 xray-core** 起本地 **dokodemo-door**(override→服务端 `127.0.0.1:22`,躲自指防环)、SSH 直连本地口经 vmess/tls:443 出去。**复用已有 :443 xray,服务端零增量**;不挂系统 VPN / 不用 tun。per-host:不配 proxy=直连(行为不变);aar 没 build=隧道不可用但直连 host 照常。**vmess + vless(Reality);vless iOS 先行,Android 待跟**。⭐ **海外 host(从国内连)= proxy 必选,不是可选**(GFW 对 :22 的 DPI 干扰持续且演化)——**初始化 host 的 agent 必须装 xray 打通 443**,见 [`docs/agent-setup-guide.md`](docs/agent-setup-guide.md) 第 4.6 步。详见 §5.1 + SPEC §5.1 |

---

## 6. Stage A 三个实验(全部已在真机闭环)

三个 80% 架构风险实验,真机部署后都已过:

- **A.1** ✅(2026-05-29):8BitDo F13/F14 在 Beam Pro **到不了 app**(`Generic.kl` 注释掉 F13–F24)→ 改用 **F1/F2**;真机端到端验证 F1 hold-to-talk 触发豆包 ASR
- **A.2** ✅:sshj + BouncyCastle 在 Beam Pro 真机加载通,SSH(含多跳 ProxyJump)端到端在用
- **A.3** ✅:WebView + xterm.js + JSBridge 真机上跑得动,大输出可用(未做正式 fps 基准,留接口可切 Base64↔localhost WebSocket)

fallback 接口(sshj↔sshlib、Base64↔WS)仍预留。完整判据见 [`docs/stage-a-experiments.md`](docs/stage-a-experiments.md)。

### Agent 状态展示(当前机制)

列表卡片显示 working / waiting / disconnected / unknown + 时长。检测走 **Claude Code hooks(事件驱动,非抓屏)**:Maestro 用 `xreal-project.sh` 建 claude/agent/maestro 类 project 时自动部署 `agent-status.sh` + hooks,事件触发写 `<base>/.xreal/status.json`;app 在列表加载时**一次性 cat** 该文件(`StatusPoller`)。**实时刷新(轮询/抓屏)是搁置的 P2**(`FleetFeatures.LIVE_STATUS=false` + `AgentStatusDetector`),当前不走那条。

### SSH-over-443 隧道(VPN / 翻墙,可选 per-host)

GFW 对 :22 限速/阻断海外 host,但同机 :443 的 xray(vmess+TLS)服务正常。app **可选**地内嵌 xray-core 起一个**仅本地** dokodemo-door inbound,把进来的 SSH 连接 override 改写成服务端 `127.0.0.1:22` 经 vmess/tls:443 送出 → SSH-over-443。**契约单一真相源 = [`SPEC.md`](SPEC.md) §5.1**,这里只记 Android 落点 + 怎么 build。

- **⚠️ 为什么 dokodemo-door 不是 SOCKS**:SOCKS 让 SSH 连 `节点IP:22`(= vmess 节点自己)会触发**自指防环 → 退化直连 → 被 GFW 卡**。override 成 `127.0.0.1:22` 躲过(详见 SPEC §5.1 + `XrayConfig` 类注释 + `~/claude/vpn/ssh-over-vmess.md`)。
- **数据流**:host **内联** `proxy{name,localPort,url}`(SPEC §8 目标契约;legacy 顶层 `proxies` 表仍兼容)→ `SettingsStore` 解析成 `ProxyConfig`(**localPort 冲突 fail-closed 拒绝整份配置,不退回直连**)→ `HostConfig.effectiveProxy(all)` 统一归属 → `XrayProxy.tunnel(proxy, "127.0.0.1", port)` 起 xray dokodemo-door 实例、用配置**固定 `localPort`** 监听 → sshj **直连** `127.0.0.1:<localPort>`(不用 SocketFactory)。
- **proxy 归属"拨公网那一跳"**(与 `via` 交互,SPEC §5.1):统一走 `effectiveProxy(all)` 解析——直连 host 用自己的 proxy;经 `via` 的内网 host → proxy 跟**跳板**走(注入跳板的 `SshJump`,内层连 127.0.0.1 不叠加)。**四个调用点**别漏:`MainActivity`(终端)、`ManifestFetcher`(manifest)、`StatusPoller`(状态)、`SshJump`(跳板外层)——漏一个就绕过隧道在 :22 hang。
- **UI**:host 头显示 `🔒 <proxy名>` 徽章(`StatusPoller.hostProxyLabel`→`effectiveProxy` + `index.html .host .hproxy`),一眼区分隧道/直连。
- **vmess + vless(Reality)**:iOS `XrayConfig` 认 `vmess://`(base64 JSON)与 `vless://`(明文 URI,`makeConfig` 按前缀分派);**Android 当前只 vmess**,对称跟进只需在 `parseVmess` 旁加 `parseVless`。`ss`/`trojan` 暂不支持,扩展只需加 URL parser。
- **不挂系统 VPN / 不用 tun / 无 VpnService 权限**——dokodemo-door 只是个本地端口,仅代理 app 自己的 SSH 连接。
- **`xraybridge.aar` 不进 git**(20MB,`.gitignore` 忽略),需**本机 build**:`cd xray-bridge && ./build.sh`(见 §10.1)。没 build → `XrayProxy.available()=false`,带 proxy 的 host 连接失败但**直连 host 照常**(优雅降级)。

---

## 7. 协作偏好(关键 — 不读这段会反复踩坑)

用户的工作风格:

- **zh-CN 输出**(技术术语保留英文,如 `xterm.js` `SSH` `WebView`)
- **简洁直接**。不要冗长解释,不要重复 user 已经说过的话。回应像同事而不是教学
- **做了再说**。不要每一步都问"要不要继续",auto mode 下默认推进
- **真正需要决策时才停下来问**(选择会显著影响后续工作的、destructive 操作、用户没说过的方向变化)
- **不要再做架构 review**。已经经过 4-5 轮收敛,你的任务是**实施**,不是 second-guessing 设计
- **不要去原 upstream 仓库 push 任何东西**(`clawzhang89-bot/term-on-demand`)。那是别人的项目,docs/07 是用户作为 contributor 提的 PR。本项目的代码在本地 + 后续用户指定 git remote
- **承认局限**。物理设备相关的事(按物理键、麦克风录音、Beam Pro 特定行为)你做不了,直接告诉用户"这里需要你协助",不要假装能验
- **代码风格**:Kotlin idiomatic;不写"教学级"长注释;复杂逻辑写一行 why,不写 what
- **commit message**:第一行简短(< 70 char),用中文 OK,带 `Co-Authored-By: Claude` trailer

---

## 8. 用户身份(如果将来 push)

用户在多账号环境,**如果将来某个时刻要 push 到 github,使用 kevinfitzroy 身份**:

- SSH host alias: `kevinfitzroy.github.com`(已在 `~/.ssh/config` 配好)
- SSH key: `~/.ssh/id_rsa_kevinfitzroy715`
- `git config user.name`: `Evan`
- `git config user.email`: `kevinfitzroy715@gmail.com`
- 设置:在仓库内 `git config user.name "Evan" && git config user.email "kevinfitzroy715@gmail.com"`(局部,不动 global)

默认全本地,**不要主动 push**。等用户说"push 到 X"再做。

---

## 9. 工具准备(环境基线)

开发环境早已就绪(Android Studio + SDK 已装,项目能编译并装到真机)。日常只需:

- **构建**:`./gradlew` 必须用 Android Studio 自带 JBR 21,见 §10.1 的 `JAVA_HOME`(系统默认 `java` 是 Java 8,AGP 8.x 不支持)
- **真机调试主力是 Beam Pro X4100**(Android 14 = API 34),adb 通道安装(NebulaOS 装 APK 见 memory `beam-pro-device`)。emulator 仅在没真机时跑非硬件逻辑用,主路径(8BitDo/麦克风)emulator 验不了
- 偶发缺工具(换机/重装)时再按需补:`command -v adb`、`command -v emulator`、Android Studio、JDK 17+

---

## 10. 常用命令

> 命令统一进这里,**HANDOFF.md 不放命令**,后续 session 找命令只看这一个地方。

### 10.1 构建 / 安装

> **重要**:系统默认 `java` 是 Java 8(老 JDK,Android Gradle Plugin 8.x 不支持)。所有 `./gradlew` 命令必须显式 set `JAVA_HOME` 到 Android Studio 自带的 JBR 21:`JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`。下面的命令已经带上。

| 操作 | 命令 | 备注 |
|---|---|---|
| 编译 Debug APK | `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug` | 产物在 `android/app/build/outputs/apk/debug/app-debug.apk` |
| 装到 emulator/真机 | `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew installDebug` | emulator 需先启动或真机已 USB 连接 |
| 全清重编 | `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew clean assembleDebug` | Gradle 缓存或依赖出问题时用 |
| **build SSH-over-443 隧道 aar(Android)** | `cd xray-bridge && ./build.sh` | 出 `android/app/libs/xraybridge.aar`(不进 git)→ 下次 assembleDebug 自动带隧道能力。**前置**:NDK r27c + gomobile/gobind + 翻墙(脚本默认走 SOCKS `127.0.0.1:10808`)。坑见 §5.1 / memory `ssh-over-443`:go.mod pin 兼容本机 go 的 xray-core 版本、`GOROOT` 须指向新 go(非 PATH)。**没 build 不影响普通构建**(隧道功能仅不可用) |
| **build SSH-over-443 隧道 framework(iOS)** | `cd singbox-bridge && ./build-ios.sh` | 出 `ios/App/Frameworks/Singboxbridge.framework`(21MB,不进 git)→ 下次 xcodebuild 自动嵌入。**iOS 隧道引擎已从 xray-core 换 sing-box**(issue #46/PR #47:xray-core 的 vless+Reality/Vision 真机连上即停,桌面 sing-box 同节点稳)。**已在本机 build 通过**(arm64,导出符号验过)。前置:**go1.25.x**(gomobile 的 x/mobile 要 1.25;本机有缓存即可,无需手动升)+ gomobile/gobind + 翻墙。脚本内置硬化:缓存 toolchain 当 GOROOT+`GOTOOLCHAIN=local`、`x/mobile` 经 tool 指令、`GOSUMDB=off`(都踩过,见 memory `ssh-over-443`)。build tag `with_utls`(reality 必需)。**没 build 不影响普通构建** |

如果嫌每次写 `JAVA_HOME` 麻烦,可以 `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` 加进 `~/.zshrc`,或在 shell 里直接 `export` 一次。

> **iOS 编译期可选功能**:`ios/App/Sources/BuildFeatures.swift` 集中放编译期开关(改常量 → 重编生效)。当前:
> `scrollRail`(终端右缘无极拨轮,#24,**默认关** = 点击半屏翻页;弱网更稳,故 opt-in)。改完需 `cd ios && xcodegen generate`(若动过文件)再 build。详见 [`ios/README.md`](ios/README.md) 「拨轮(可选)」。

### 10.2 测试 / lint

| 操作 | 命令 | 备注 |
|---|---|---|
| 单元测试(全部) | `cd android && ./gradlew test` | JVM 测试 |
| 单测(单个类) | `cd android && ./gradlew test --tests "io.github.kevinfitzroy.xrealclient.ManifestFetcherTest"` | 替换全限定类名(现有:ManifestFetcher / Hotwords / VolcFrame / PcmChunker 等)|
| Lint | `cd android && ./gradlew lint` | 报告在 `android/app/build/reports/lint-results-debug.html` |

### 10.3 Emulator / adb

| 操作 | 命令 | 备注 |
|---|---|---|
| 启动 emulator | `$HOME/Library/Android/sdk/emulator/emulator -avd Pixel_8a &` | 用全路径(emulator 不在 PATH);AVD 名按实际:当前 user 有 `Pixel_8a`(target android-37,arm64-v8a)|
| adb 设备列表 | `adb devices` | |
| 模拟 F1=语音(KEYCODE 131) | `adb shell input keyevent 131` | 主路径(真机 8BitDo B 键发 F1)。**F13/F14(326/327)在 Beam Pro 到不了 app**(Generic.kl 注释掉),别再用 |
| 模拟 F2=返回列表(KEYCODE 132) | `adb shell input keyevent 132` | 终端 → 列表 |
| 模拟翻页 Shift+↑ / Shift+↓ | `adb shell input keycombination 59 19` / `... 59 20` | 59=SHIFT_LEFT,19/20=DPAD_UP/DOWN(真机 8BitDo R 键=Shift)→ tmux root 表进 copy-mode 半页滚(见 §6/§5)。命令语法在真机验过;是否端到端进 copy-mode 需在终端态内自测 |
| 看 app 日志(过滤) | `adb logcat -s VoiceDaemon:V SshConnection:V TerminalBridge:V` | tag 名按 Kotlin 代码里实际声明 |
| 清空 logcat | `adb logcat -c` | |
| **拉持久化崩溃/连接日志** | `adb pull /sdcard/Android/data/io.github.kevinfitzroy.xrealclient/files/logs/app.log` | `AppLog` 写的文件日志(生命周期/SSH 连接/display 增删/WebView render-gone/全局未捕获崩溃栈)。NebulaOS 直接 pull,不需 run-as。超 512KB 滚一份 `app.log.1` |
| **重开后看上次为啥崩** | `adb logcat -s AppLogPrev` | app 一启动就把上一会话(上次进程)日志尾部重喷 logcat。闪退在眼镜上发生、当时没接电脑也能事后复盘 |

### 10.4 服务端 / host(生产 host 脱敏名 = jump-edge / private-worker;本机 Mac 当临时测试 host)

| 操作 | 命令 | 备注 |
|---|---|---|
| Maestro 建 project(自动部署状态 hooks) | `<base>/.xreal/xreal-project.sh new claude <session> [名]` | claude/agent/maestro 类型 `new` 时自动装 `agent-status.sh` + hooks → 写 `.xreal/status.json` |
| 给现有 project 补/刷状态 hooks | `<base>/.xreal/xreal-project.sh hooks` | `hooks` 子命令:给 manifest 里所有 AI-agent project 一次性铺开 hooks(已有 host 升级用) |
| 列 / 删 project | `xreal-project.sh ls` / `xreal-project.sh rm <session> [--kill]` | rm 从 manifest 移除,`--kill` 同时杀 tmux session |
| 重启后拉回整个 deck | `<base>/.xreal/xreal-project.sh restore` | 幂等重建 manifest 里所有 tmux session(maestro 守护 loop + 各 project,已在则跳过)。主机重启后用 |
| 装开机自启(@reboot cron) | `<base>/.xreal/xreal-project.sh install-autostart` | 重启后自动 `restore`;免 root。systemd user service 替代方案见 agent-setup-guide.md 第 4.5 步 |
| host 接入步骤 | 见 [`docs/agent-setup-guide.md`](docs/agent-setup-guide.md) | banner 隐 IP、Maestro 保活、开机自启等 |
| 开启 Mac sshd(临时测试 host) | System Settings → Sharing → Remote Login | 验证:`sudo systemsetup -getremotelogin` 输出 `Remote Login: On` |
| abduco(纯 SSH project 的 session 驻留备选) | `brew install abduco` → `abduco -A dev bash`(`abduco` 列出) | agent 类 project 用 tmux(需 capture-pane);见 §5 session 驻留行 |

### 10.5 Git(本地,不 push)

| 操作 | 命令 | 备注 |
|---|---|---|
| 局部设置 commit 身份 | `git config user.name "Evan" && git config user.email "kevinfitzroy715@gmail.com"` | 详见 §8;不动 global |
| 普通 commit | `git commit -m "..."` 带 `Co-Authored-By: Claude` trailer | 详见 §7 |

### 10.6 测试工具:把本机 Mac 配成真 host + 电脑打字直通手机终端

调试期持续测试手机 terminal 显示用。详情见两个脚本头部注释。

| 操作 | 命令 | 备注 |
|---|---|---|
| 一键搭测试 host | `./scripts/setup-mac-host.sh [项目目录]` | 幂等:起 tmux(`main` 跑真 claude / `shell`)、adb reverse(SSH)+forward(relay)、push key+hosts.json、重启 app。reboot 后(`/data/local/tmp` 清零)重跑 |
| 电脑打字直通手机终端 | `python3 scripts/term-relay.py` | 先在手机上进入一个 project 终端;raw 模式键盘→手机,`Ctrl+]` 退出。底层是往 app 的 DebugInputServer(:8889)发裸字节 |

> 机制:`loadHosts()` 读 `/data/local/tmp/xreal_hosts.json`(无则空,走 mock)。`DebugInputServer` 只在 **debug build + hosts.json 存在**时监听 `127.0.0.1:8889`(生产/未配置不监听)。私钥文件须 `chmod 644`(app uid 要能读,600 会 EACCES)。

---

## 11. 何时去读 upstream docs

上游仓库 `clawzhang89-bot/term-on-demand` 的关键 docs 索引见 [`docs/upstream-docs-index.md`](docs/upstream-docs-index.md)。

简单规则:
- **不需要主动去读**。本项目 `docs/` 下我已经把跟实施直接相关的都浓缩过来了
- **以下情况去读**:
  - 用户提到具体的 issue 号(#1/#4 等)— 用 `gh issue view N -R clawzhang89-bot/term-on-demand` 看
  - 你对某个架构决策有疑问 — 读 `docs/06` / `docs/07` 看 trade-off 讨论
  - 用户问"为什么不...?"— 通常 docs/06 §0.5、§2 备选方案、§7 关键决策有答案

---

## 12. 立刻可以执行的第一步

**先读 [`HANDOFF.md`](HANDOFF.md)**(动态状态文档),它告诉你 user 当前实际在哪一步、哪些已经准备好、第一步该怎么走(按 user 状态分了 A/B/C/D 四种情形)。

简短规则:
- user 没说话 / 第一次启动 → 读 HANDOFF.md 看当前在哪、最近一轮做到哪 → 行动
- user 直接给具体任务(改 bug / 加能力)→ 用 §4 代码地图定位模块 → 干
- user 问"项目是啥" → 复述 §1-§3(已部署真机系统),问 user 想从哪开始

HANDOFF.md 也定义了**何时该更新它自己**,保持长期可用。

---

## 13. 项目根目录结构(当前)

```
/Users/foxer/claude/xreal-ai-client/
├── CLAUDE.md                    ← 本文件
├── HANDOFF.md                   ← 动态状态(当前进度,先读它)
├── SPEC.md                      ← 客户端契约(平台中立单一真相源,Android/iOS 共同实现;改跨端行为先改它)
├── README.md                    ← 给人类看的目录说明
├── docs/
│   ├── background.md / architecture.md           ← 背景 + 架构
│   ├── session-persistence-options.md            ← tmux vs abduco
│   ├── stage-a-experiments.md                    ← Stage A 实验 + pass/fail
│   ├── upstream-docs-index.md                    ← 上游 docs 索引
│   ├── orchestrator-CLAUDE.md / agent-setup-guide.md  ← host 上 Maestro 指南 + 接入步骤
│   ├── xreal-project.sh                           ← Maestro 建/进 project + 部署状态 hooks
│   └── projects.example.json / images/
├── xray-bridge/                 ← SSH-over-443 隧道:gomobile 封 xtls/xray-core 成 aar(bridge.go/build.sh;§5.1)
├── android/                     ← Android Studio 项目(已建,真机在跑)
│   └── app/src/
│       ├── main/kotlin/io/github/kevinfitzroy/xrealclient/  ← 26 个 .kt(见 §4 代码地图:
│       │     SshConnection/SshJump/PtyChannel、TerminalBridge、VoiceDaemon/VolcEngineAsr、
│       │     MainActivity/StatusPoller/AgentModels、XrayProxy/XrayConfig(隧道)、XrealApp/AppLog 等)
│       ├── main/assets/terminal.html             ← xterm.js + WebGL + unicode11 + overlay
│       └── test/kotlin/...                        ← JVM 单测(ManifestFetcher/Hotwords/VolcFrame 等)
└── scripts/                     ← setup-mac-host.sh、term-relay.py(调试期测试工具,见 §10.6)
```

## 语音输入约定(xreal-ai-client)

本会话的用户用 AR 眼镜 + 语音操作。以 `🎤 ` 开头的用户消息 = **语音转写**,可能有同音字 / 断词 / 专名识别错误。

- **按意图理解,主动纠错**:别照字面执行明显是识别错的内容;不确定时先复述你的理解再动手。
- **专名反复错** → 主动提示用户:"要把『X』加进这个项目的热词表吗?" 用户同意后,告诉 Maestro 把它加进本项目 manifest 的 `hotwords`(或让 Maestro 直接改)。热词表是 **project 级**的,各项目独立。
- 非 `🎤 ` 开头的消息是键盘输入,正常对待。
