# 项目背景:为什么要做这个 App

> 这份文档让你理解**整个项目的来龙去脉**。读完之后,你会明白每一个架构决策为什么是这样,而不是别的样。

---

## 1. 用户和场景

**用户**:Evan(GitHub `kevinfitzroy`),个人开发者。日常做远程服务器开发(Linux + Docker + Kubernetes + AI agent 工作流),工作环境分散:家、咖啡馆、公园、通勤路上。

**核心痛点**:笔记本不够便携 — 但是开发场景对屏幕的需求(看 terminal、看 PR diff、看 dashboard)又让手机 + 平板都太局促。

**新硬件栈**(2025-2026 年成熟):
- **XREAL One Pro AR 眼镜**(¥4299):全彩 1080p,57° FOV,700 nits 亮度,自研 X1 芯片 + 原生 3DoF 屏幕悬停 — **戴上之后眼前就是一个"虚拟显示器"**,可以是 80×24 的 terminal,也可以是浏览器
- **Beam Pro**(¥1299 起):XREAL 配套的小型 Android 14 主机(口袋大小),双 USB-C,跑 nebulaOS,接 AR 眼镜做显示
- **8BitDo Micro 蓝牙小键盘**(¥180):6 键 + 方向键,可发标准 HID 键码,贴在 Beam Pro 背面随身携带

这套硬件的总成本 ~¥6000-7000,体积、重量、便携性远胜笔记本。但**软件还跟不上**。

---

## 2. 软件层的核心矛盾

AR 眼镜 + 小键盘 + 语音 的新交互模式有一个**隐含约束**:

> **鼠标和触摸都不方便**(你戴着眼镜,看不见屏幕上的指针,Beam Pro 在口袋或桌上,触屏需要拿出来)
>
> **物理键就这么几个**(8BitDo Micro 6-10 键)
>
> **所以输入方式只能优先 terminal + 语音**

这个约束反推出整套设计:
- 主路径:**终端**(纯键盘交互天然适配)
- 补丁:**语音**(描述需求、说路径、回答问题)
- 可视化(图表、表格、PR review):AI agent 现场生成 HTML 放 nginx → 浏览器看一眼 → 关掉

详见上游项目 `term-on-demand` 的核心理念(链接见 `upstream-docs-index.md`)。

---

## 3. 为什么不用现成的 SSH client

候选 SSH client:Termius / Termux / Blink Shell / ConnectBot / JuiceSSH / Tabby Mobile / ...

**核心问题**:它们都不能满足三个并存的需求:

| 需求 | 为什么现成 client 做不好 |
|---|---|
| **UI 现代化,适合 AR 眼镜显示** | Termux UI 是 80 年代风,ConnectBot 类似;Termius 闭源不可定制;Tabby Mobile 不成熟 |
| **接受 Beam Pro 端 ASR 文本注入** | Android 安全模型:`SYSTEM_ALERT_WINDOW` 不能跨 App 注入键盘事件;`AccessibilityService` 在 SSH client 的 SurfaceView 输入区上通常不工作;`IME` 与 8BitDo 物理键盘冲突 |
| **支持 8BitDo 物理键(F1/F2)作为 PTT / 导航触发** | 没法在第三方 client 内部拦截 keycode 用作"我的按键",会跟 client 自己的快捷键打架(原设计 F13/F14,实测改 F1/F2,见 §8)|

之前的方案尝试过(详见上游 `docs/06` 的多版本演进):
- 双端 Voice Gateway(云端跑 ASR + LLM + tmux send-keys 注入)→ 架构复杂,服务端需要新增一个长 lived 服务
- 剪贴板桥接 + Claude Code(Voice Daemon 写剪贴板,用户按物理粘贴键)→ 跨 App 注入难题在 Android 14 上没干净的零权限解
- Termux + Intent(Termux 的 RUN_COMMAND Intent 接收文本)→ Termux UI 老,不解决 UI 问题

**收敛到当前方案**:**自己写一个 Android App**,SSH 协议 + 终端渲染 + 按键事件 + 语音输入全部在同一进程,所有跨 App 难题 / 服务端复杂度都消失,UI 完全自己控制。

---

## 4. 为什么是 WebView + xterm.js,不是原生 Compose

终端模拟器是个深坑(ANSI 转义、Unicode 宽字符、240 色、滚动 buffer、Sixel 图片、shell 历史搜索等)。从零写一个 Compose 版要数月。

[xterm.js](https://github.com/xtermjs/xterm.js) 是 **VS Code、Hyper、wetty 共用的核心 terminal 库**,5+ 年沉淀,WebGL renderer 60fps 流畅,所有 ANSI 边角都处理好。

**包到 WebView 里直接用**,我们只需要:
- 自己写 CSS 控制视觉(暗色、字体、行间距、圆角等 — 完全像 web 开发)
- 自己写一个简单 JS 桥接收 Kotlin 端的 SSH 字节,推给 xterm.js;反方向也一样

代价:WebView 多一层,有性能开销 — 但对 SSH 这种 KB/s 量级输出无感。**这是用 1 周工程量换 6 个月工程量的事**。

---

## 5. 为什么用 sshj 直连,不用 ttyd / 服务端中转

`ttyd` 是为"桌面浏览器远程访问 server" 设计的(浏览器沙箱不能开 raw TCP,必须经 WebSocket)。但**我们是 Android App 内的 WebView**,Android 进程本身能开 raw TCP,**根本不需要 WebSocket 中转**。

直接在 Kotlin 用 [sshj](https://github.com/hierynomus/sshj) 库连服务器 SSH 22 端口:
- 一行 `SSHClient().connect(host).authPublickey(...).startSession().startShell()`
- 服务器零增量 — 它只是被一个标准 SSH client 连接,跟 OpenSSH 没区别

这一点的工程意义:**服务端运维角度,这个 App 跟一个普通 SSH client 没有任何区别**。不需要在服务端装任何东西。

---

## 6. 为什么 Voice Daemon 直接写 SSH outputStream

最自然的设计是 Voice Daemon 拿到 ASR 文本后,调 `webView.evaluateJavascript("term.paste(...)")` 让 xterm.js "粘贴" 文本。

更简单的设计:Voice Daemon **直接** `ssh.outputStream.write(text)`,字符走 SSH 到远端 shell,**shell 默认 echo on**,把收到的字符回送,回送的字节流通过 SSH 回到本地,xterm.js 渲染。

**Voice Daemon 完全不需要知道 xterm.js 存在**。少一个集成点,少一类 bug。

---

## 7. 为什么 Overlay 是 WebView 内 HTML,不是 SYSTEM_ALERT_WINDOW

旧方案(剪贴板桥接版)需要 `SYSTEM_ALERT_WINDOW` 权限,因为 overlay 要浮在"其他 App(Termius)"之上。

本设计 overlay 就在自己的 WebView 里,**只是个 `<div>`**,通过 JSBridge show/hide。**零权限,零跨 App,零问题**。这是 advisor 在最后一轮 review 时帮我们看到的简化点。

---

## 8. 物理键:原设计 F13/F14,实测改成 F1/F2

原设计想用 F13–F24 这些"扩展功能键"(KEYCODE_F13 = 326 等):普通 App 不占用它们,理论上零冲突。

**但 Stage A.1 实测(2026-05-29)推翻了它**:Beam Pro 的 8BitDo 走 `/system/usr/keylayout/Generic.kl`,其中 F13–F24 全被注释 → keycode 映射不出、系统在送达前丢弃,**到不了 app**。

改定的主路径:**F1 = 语音(hold-to-talk)、F2 = 返回 project 列表**(F1–F12 在 `Generic.kl` 活跃)。`MainActivity.dispatchKeyEvent` 拦 `KEYCODE_F1/F2`;Ctrl+Alt+1/2 保留作备路径;F13/F14 代码分支留给其它设备兜底。详见 README「操作」章节 + memory `beam-pro-device`。

---

## 9. 语音 → 命令 还是 语音 → 意图

旧版本设计里有过"Voice Gateway 把语音翻译成 shell 命令的 top-3 候选,用户选" 的设想。本设计**砍掉了 LLM 翻译这一层**:

- Voice Daemon 把 ASR 文本**原样**写进 SSH outputStream
- 服务端的 `claude code` 会话本身就是个 agent,它收到自然语言输入会理解意图、提议命令、等用户确认执行
- **少一个 LLM 调用 = 省一段延迟 + 省一份费用 + 少一个错误源**

也就是说,语音的角色是"喂给 Claude Code 的 user prompt",而 Claude Code 本身做意图理解。

---

## 9.5 现状:多 host 指挥台 + 多跳接入(已真机部署)

App 已在 Beam Pro X4100 真机部署跑通,不再是单 host 设想,而是 **Host → Project 两级的 AI agent 指挥台**:

- 两台真实 host:**TK-ALIYUN**(海外,user=xreal,直连)、**OPS**(AWS 内网,user=ubuntu,**经 TK 多跳到达**);各跑 Maestro orchestrator 维护项目清单。
- **多跳 SSH(ProxyJump)**:OPS 只 VPN 可达。`HostConfig.via = "TK-ALIYUN"` → app 先连 TK,经它本地端口转发到 OPS,**认证端到端打到 OPS**(TK 只转发 TCP)。VPN(OpenVPN→AWS Client VPN)现在挂在 **TK 服务器上,手机不再挂 VPN** —— 比早期"手机装 OpenVPN"的方案干净得多(memory `openvpn-on-beam-pro` 是更早的过渡态)。
- **Agent 状态展示走 Claude Code hooks**(事件驱动,非抓屏):agent 事件 → 服务端写 `.xreal/status.json` → app 一次性 cat 显示 working/waiting/disconnected。详见 [`architecture.md`](architecture.md) §3.6。

这些都不破坏"服务端零增量":`.xreal/` 里的脚本是用户自己 project 目录下的一次性部署,没有新增长 lived 服务。

---

## 10. 总结一句话

**一个 Android App,WebView 跑 xterm.js 当漂亮 terminal UI,Kotlin 用 sshj 连云端 SSH(内网 host 经跳板多跳),同 app 内一个 Voice Daemon 录音 → 豆包 ASR → 直接写 SSH outputStream。多 host / 多 project 指挥台,agent 状态走 Claude Code hooks。服务端零增量,只跑用户已有的 tmux + Claude Code。**

每一个设计决策都源于一个具体的 trade-off,详见 [`architecture.md`](architecture.md) §7 关键技术决策。如果你想理解某个 deeper 的"为什么不",上游 `docs/06` 的多版本历史是完整的。
