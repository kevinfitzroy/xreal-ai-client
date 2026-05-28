# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

# XREAL AI Client — Claude Code 项目指南

> **你正在加载一个 cold-start session**。这份文档让你立即知道:你是谁、要做什么、为什么、关键约束、协作偏好。读完这份之后,根据需要去 `docs/` 看更深的内容。

---

## 1. 你的角色

你是这个项目的**实施 agent**。

**任务**:实现一个 Android App,把 SSH client + 终端 UI + 语音输入全部塞进同一个进程,跑在 XREAL AR 眼镜 + Beam Pro 上,让用户通过物理按键 + 语音操作远程服务器上的 Claude Code。

**当前 phase**:**Phase 0 — Mac 上脚手架 + Android Emulator 验证**(不需要任何 Android 物理设备,你可以独立完成 80% 工作)。

**不在 Phase 0 范围**:
- 8BitDo 物理按键真机测试(必须用户在场 + 物理设备,留给 Phase 1)
- 麦克风真机录音端到端(emulator 麦克风太弱,留给 Phase 1)
- Beam Pro 特定的 NebulaOS 后台 / GPU / AR 显示验证(留给 Phase 2)

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
│  ├─ HID 监听 F13/F14 (8BitDo 物理键)                     │
│  ├─ AudioRecord → Opus → 豆包 ASR                       │
│  ├─ WebView.evaluateJavascript("showOverlay(...)")       │
│  └─ Enter 确认 → sshSession.outputStream.write(text)    │
│                                                          │
└────────────────┬─────────────────────────────────────────┘
                 │ Raw SSH (port 22)
                 ▼
       海外 Ubuntu 服务器
       └─ tmux: dev session → claude code --resume
       (无 ttyd / 无 nginx / 无 Voice Gateway —— 跟标准 SSH 接入完全一样)
```

详细版含可编译代码骨架:[`docs/architecture.md`](docs/architecture.md)。

---

## 4. Phase 0 完成清单(你的具体任务)

按顺序做。每完成一项就向用户汇报,不要批量打包。

- [ ] **0.1** 在 `/Users/foxer/claude/xreal-ai-client/android/` 下 init Android Studio 项目(Kotlin,minSdk 34,targetSdk 35)
- [ ] **0.2** 加 sshj 0.39+ 依赖,写 `SshConnection` 类(connect / authPublickey / allocatePTY / startShell / read / write / resize / disconnect)
- [ ] **0.3** Mac 自己开 sshd(`System Preferences → Sharing → Remote Login`),用 emulator 跑 SSH 连本机,验证基本命令(`ls / vim / Ctrl+C`)。**SSH session 驻留方案默认用 abduco**(不要硬编码 tmux,见 [`docs/session-persistence-options.md`](docs/session-persistence-options.md))— Phase 0 测试时 Mac 上 `brew install abduco`,启动命令默认 `abduco -A dev bash`,留接口允许用户切到 tmux/screen
- [ ] **0.4** 写 `assets/terminal.html`(xterm.js + WebGL addon + 暗色主题 + overlay 元素),WebView 加载
- [ ] **0.5** 写 `TerminalBridge`(Kotlin `@JavascriptInterface` + Base64 双向桥接),把 SSH inputStream 推 WebView,把 WebView onData 写 SSH outputStream
- [ ] **0.6** 写 `VoiceDaemon` 状态机骨架(纯逻辑,先不接豆包 — mock 一个 "fake ASR 返回固定文本",验证 overlay show/hide + Enter 写 SSH 路径)
- [ ] **0.7** `dispatchKeyEvent` 路由:`KEYCODE_F13`/`KEYCODE_F14`(raw int 326/327)→ VoiceDaemon;Enter/Esc 按 overlay 状态决定
- [ ] **0.8** APK 编译产出,在 emulator 上能演示:WebView 里按键 → 字符进 SSH → 输出回流 + emulator 模拟 F13 触发 mock 录音 → overlay 显示 → Enter 注入文本

Phase 0 验证通过的标准:**用 Android emulator(Pixel 7 Pro API 34)就能演示整套架构的"非硬件依赖"部分都跑通**。

Phase 0 完成后产出 git commit(本地)+ 给用户一个"Phase 0 done" 报告,**等用户决定何时开始 Phase 1**(连真机做 8BitDo / 真麦克风测试)。

---

## 5. 关键约束(不要 deviate)

这些都是经过 4-5 轮架构 review 收敛下来的决策,**不要重新挑战**。如果你觉得某条需要调整,先告诉用户,等批准再动。

| 约束 | 解释 |
|---|---|
| **零服务端增量** | 不要引入 ttyd / nginx / 任何云端 Voice Gateway / tmux-send-keys daemon。服务端只跑用户已有的 tmux + Claude Code |
| **单 App 闭环** | 不要做"主 app + 辅助 service"双进程架构。所有逻辑在一个 APK 内 |
| **Overlay = WebView 内 HTML** | 不要用 `SYSTEM_ALERT_WINDOW` 权限。Voice 预览 overlay 就是 WebView 里的 `<div>`,通过 JSBridge show/hide |
| **Voice → SSH 直写** | Voice Daemon 拿到 ASR 文本,**直接写 ssh.outputStream**,字符走 SSH 到远端 shell,shell echo 回送,xterm.js 渲染。Voice 路径不需要知道 xterm.js 存在 |
| **不用 Accessibility / IME** | 不需要这两个权限。同 app 内事件路由用 `Activity.dispatchKeyEvent` |
| **F13/F14 keycode 主路径,Ctrl+Alt+1/2 备路径** | 8BitDo Ultimate Software 官方支持 F13-F24,但 Beam Pro 真机是否收到 KeyEvent 326/327 是 Phase 1 实测项;Phase 0 代码两条都写,优先 F13/F14 |
| **服务端 session 驻留默认 abduco,不是 tmux** | 用户 tmux 体感差(卡 + 历史难查),客户端 xterm.js 已有 10000 行 scrollback + 搜索,服务端只需"session 不死",abduco 更契合。`SshConnection` 应该把启动命令做成可配置,不要硬编码。详见 [`docs/session-persistence-options.md`](docs/session-persistence-options.md) |
| **优雅降级** | 任何组件挂了,用户能退回 Termius / Termux 继续工作。App 不是必需品 |

---

## 6. Stage A 三个实验(物理设备到位后的验证项)

Phase 0 写的代码,等用户拿到物理设备后,跑这 3 个 ~1 周的实验决定 80% 架构风险:

- **A.1**(1 天)8BitDo Micro F13/F14 在 Beam Pro / Android 14 上 KeyEvent 是否收到 326/327
- **A.2**(2 天)sshj 0.39+ 在 Beam Pro 真机上 BouncyCastle 加载是否通
- **A.3**(2 天)WebView + xterm.js + JSBridge 在 Snapdragon 7 Gen 2 GPU 上 60fps 大输出是否流畅

每个实验有 named fallback。**完整 pass/fail 判据 + fallback 路径见 [`docs/stage-a-experiments.md`](docs/stage-a-experiments.md)**。

你 Phase 0 写代码时,把这 3 个实验的 fallback 路径都预留接口(比如 SSH 模块要能切换 sshj↔sshlib,JSBridge 要能切换 Base64↔localhost WebSocket)。

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

但 **Phase 0 默认全本地,不要主动 push**。等用户说"push 到 X"再做。

---

## 9. 工具准备(用户 Mac 上需要装什么)

如果用户第一句话是"开始",先 verify 这些工具,缺啥引导他装:

```bash
# 检查清单(你可以直接跑 Bash 验证)
command -v adb || echo "缺 Android SDK platform-tools"
command -v emulator || echo "缺 Android emulator"
test -d /Applications/Android\ Studio.app && echo "Android Studio OK" || echo "缺 Android Studio"
java -version 2>&1 | head -1  # 需要 JDK 17+
brew list openjdk@17 2>&1 | head -1 || echo "brew install openjdk@17"
```

如果用户没装 Android Studio:
- 推荐从 [developer.android.com/studio](https://developer.android.com/studio) 直接下载首推的 stable 版本(2026-05 是 **Panda 4 Patch 1**,代号按动物字母滚动)
- Mac 上选 `*-mac_arm.dmg`(Apple Silicon,M 系列)或 `*-mac.dmg`(Intel)
- 也可以 `brew install --cask android-studio`(会触发权限提示)
- **不要纠结具体版本号**:Android Studio 只有一个版本(不像 IntelliJ 有 Ultimate/Community),首推 stable 即可

第一次启动 Android Studio 时它会下 Android SDK,通常 ~5-10GB,会需要 20-60 分钟。配置时确认:
- **Android SDK Platform 34**(Beam Pro 是 Android 14 = API 34)已装
- 在 **Tools → Device Manager** 创建一个 Pixel 7 Pro API 34 emulator 用于 Phase 0 验证

---

## 10. 常用命令(Phase 0 完成时填充)

> Android 项目还没 init,这一节先占位。每完成一个 Phase 0 子任务,把可重复跑的命令补进对应小节。**HANDOFF.md 不放命令,命令统一进这里**,后续 session 找命令只看这一个地方。

### 10.1 构建 / 安装

> **重要**:系统默认 `java` 是 Java 8(老 JDK,Android Gradle Plugin 8.x 不支持)。所有 `./gradlew` 命令必须显式 set `JAVA_HOME` 到 Android Studio 自带的 JBR 21:`JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`。下面的命令已经带上。

| 操作 | 命令 | 备注 |
|---|---|---|
| 编译 Debug APK | `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug` | 产物在 `android/app/build/outputs/apk/debug/app-debug.apk` |
| 装到 emulator/真机 | `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew installDebug` | emulator 需先启动或真机已 USB 连接 |
| 全清重编 | `cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew clean assembleDebug` | Gradle 缓存或依赖出问题时用 |

如果嫌每次写 `JAVA_HOME` 麻烦,可以 `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` 加进 `~/.zshrc`,或在 shell 里直接 `export` 一次。

### 10.2 测试 / lint

| 操作 | 命令 | 备注 |
|---|---|---|
| 单元测试(全部) | `cd android && ./gradlew test` | JVM 测试 |
| 单测(单个类) | `cd android && ./gradlew test --tests "com.xreal.aiclient.SshConnectionTest"` | 替换全限定类名 |
| Lint | `cd android && ./gradlew lint` | 报告在 `android/app/build/reports/lint-results-debug.html` |

### 10.3 Emulator / adb

| 操作 | 命令 | 备注 |
|---|---|---|
| 启动 emulator | `$HOME/Library/Android/sdk/emulator/emulator -avd Pixel_8a &` | 用全路径(emulator 不在 PATH);AVD 名按实际:当前 user 有 `Pixel_8a`(target android-37,arm64-v8a)|
| adb 设备列表 | `adb devices` | |
| 模拟 F13(KEYCODE 326) | `adb shell input keyevent 326` | Stage A.1 之前只能这样模拟;真机 8BitDo → F13 是否被收到要 Phase 1 验 |
| 模拟 F14(KEYCODE 327) | `adb shell input keyevent 327` | 同上 |
| 看 app 日志(过滤) | `adb logcat -s VoiceDaemon:V SshConnection:V TerminalBridge:V` | tag 名按 Kotlin 代码里实际声明 |
| 清空 logcat | `adb logcat -c` | |

### 10.4 服务端验证(Phase 0 用 Mac 本机 sshd)

| 操作 | 命令 | 备注 |
|---|---|---|
| 开启 Mac sshd | System Settings → Sharing → Remote Login | 系统级设置,user 手动 |
| 验证 sshd 在跑 | `sudo systemsetup -getremotelogin` | 输出 `Remote Login: On` 即可 |
| 装 abduco(默认 session 驻留方案) | `brew install abduco` | |
| 启动 / attach abduco session | `abduco -A dev bash` | `-A` = attach 或 create |
| 列出 abduco session | `abduco` | |

### 10.5 Git(本地,不 push)

| 操作 | 命令 | 备注 |
|---|---|---|
| 局部设置 commit 身份 | `git config user.name "Evan" && git config user.email "kevinfitzroy715@gmail.com"` | 详见 §8;不动 global |
| 普通 commit | `git commit -m "..."` 带 `Co-Authored-By: Claude` trailer | 详见 §7 |

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
- user 没说话 / 第一次启动 → 跑 §9 工具检查 → 看 HANDOFF.md §5 选情形 → 行动
- user 直接说"开始 / go" → 跑 §9 工具检查 → 进 Phase 0 §4 任务 0.1
- user 问"项目是啥" → 复述 §1-§3,问 user 想从哪开始

HANDOFF.md 也定义了**何时该更新它自己**(每次 phase 切换时),保持长期可用。

---

## 13. 项目根目录结构(Phase 0 完成后大致样子)

```
/Users/foxer/claude/xreal-ai-client/
├── CLAUDE.md                    ← 本文件
├── README.md                    ← 给人类看的目录说明
├── docs/
│   ├── background.md                  ← 完整项目背景 + 为什么
│   ├── architecture.md                ← 完整架构 + 可编译代码骨架
│   ├── session-persistence-options.md ← tmux 替代方案调研 + 推荐(abduco)
│   ├── stage-a-experiments.md         ← Stage A 实验 + pass/fail
│   └── upstream-docs-index.md         ← 上游 docs 链接 + 何时读
├── android/                     ← Android Studio 项目(Phase 0 你来 init)
│   ├── app/
│   │   ├── src/main/kotlin/...
│   │   └── src/main/assets/terminal.html
│   ├── build.gradle.kts
│   └── settings.gradle.kts
└── scripts/                     ← 可选,setup 脚本等
```
