# 架构详解 + 可编译代码骨架

> 这份文档是从上游 `term-on-demand` 仓库的 `docs/07-android-app-architecture.md` 摘出 + 针对实施需要做了一些补充的版本。所有代码骨架都是 **可编译起点**,不是教学伪代码。

---

## 1. 设计原则(必须遵守)

1. **单 Android App 闭环** — SSH 协议 / 终端渲染 / 按键事件 / 录音 / ASR / overlay,全部在一个 APK 内。无跨 App 通信、无 IME 注入、无 Accessibility,无 `SYSTEM_ALERT_WINDOW`
2. **零服务端增量** ⭐ — 服务端只跑用户已有的 shell + `claude code`。无 ttyd、无 nginx、无 Voice Gateway。从服务端运维角度,本 App 跟普通 SSH client 没区别
3. **UI 完全 WebView 实现** — terminal 用 xterm.js,候选/状态 overlay 是 WebView 里的 HTML 元素。Android 端只管 SSH 字节流 + 按键事件 + 音频
4. **Voice 直写 SSH channel,跳过 xterm.js** — Voice Daemon 拿到 ASR 文本后**直接写 SSH 输出流**,字符通过 shell echo 在远端回显,xterm.js 渲染 — Voice Daemon 不需要知道 xterm.js 存在
5. **优雅降级** — App 挂了,任何 SSH client 都能继续工作。App 是体验增强,不是必需品
6. **服务端 session 驻留:agent 类 project 用 tmux** — 产品升级成 AI agent 指挥台后,状态/预览需要 tmux 能力,agent 类走 tmux(`tmux new -A -s <session>`);纯 SSH 仍可 abduco。详见 [`session-persistence-options.md`](session-persistence-options.md)。`SshConnection` 把启动命令做成可配置

---

## 2. 整体架构

```
┌─ Beam Pro 上的一个 APK ──────────────────────────────────┐
│                                                          │
│  ┌─ WebView(全屏 immersive)──────────────────────┐    │
│  │  xterm.js + WebGL renderer + 自定义 CSS 主题    │    │
│  │  HTML overlay(Voice 预览框,纯 DOM 元素)       │    │
│  └──────────────────────────────────────────────────┘    │
│         ↑ JS:term.write(bytes)   ↓ JS:onData(bytes)    │
│         │                         │                      │
│  ┌─ JSBridge(Base64 over evaluateJavascript)───┐       │
│  │  Kotlin ↔ JavaScript                          │       │
│  └────────────────────────────────────────────────┘     │
│         ↑                         ↓                      │
│  ┌─ SSH 模块(sshj 0.39+)────────────────────────┐    │
│  │  TCP socket → SSH 协议 → PTY                    │    │
│  │  inputStream.read()   outputStream.write()      │    │
│  └─────────────────────────────────────────────────┘    │
│         ↑                                                │
│         │ Voice Daemon 直接调 outputStream.write(text)   │
│         │                                                │
│  ┌─ Voice Daemon(Foreground Service)──────────┐       │
│  │  HID 按键监听(F1/F2 实测;F13/F14 兜底)       │       │
│  │  AudioRecord → Opus → 豆包 ASR                │       │
│  │  WebView.evaluateJavascript("showOverlay(..)") │      │
│  │  Enter → sshSession.outputStream.write(text)  │       │
│  └────────────────────────────────────────────────┘     │
│                                                          │
└────────────────┬─────────────────────────────────────────┘
                 │ Raw SSH (port 22)
        ┌────────┴─────────────────────────────────────┐
        ▼ 直连                                          ▼ 多跳(ProxyJump)
  TK-ALIYUN(海外)                            TK-ALIYUN  ──本地端口转发──▶  OPS(AWS 内网)
  user=xreal                                  (挂 OpenVPN→AWS Client VPN)   user=ubuntu,经 TK 到达
  └─ tmux: <session> 跑 claude                端到端认证打到 OPS,手机不挂 VPN
     └─ Maestro orchestrator + .xreal/{projects.json,status.json}
     (无 ttyd / 无 nginx / 无 Voice Gateway —— 服务端只跑 tmux + Claude Code)

  Agent 状态展示(事件驱动,非抓屏):
    Claude Code hook(UserPromptSubmit→working / Stop→waiting / SessionEnd→disconnected)
      → <base>/.xreal/agent-status.sh 写 .xreal/status.json
      → app(ManifestFetcher)一次性 cat → 列表卡片 working/waiting/disconnected/unknown
```

**多跳 SSH(ProxyJump)**:OPS 在 AWS 内网,只 VPN 可达。`HostConfig.via = "TK-ALIYUN"` → `SshJump`(sshj 本地端口转发)先连 TK,把 `127.0.0.1:<随机口>` 转发到 OPS:22,真正的 SSHClient 连本地口 ——**SSH 认证端到端打到 OPS,TK 只转发 TCP、不持有 OPS 凭证**。OpenVPN/AWS Client VPN 挂在 TK 上,**手机不再挂 VPN**。

---

## 3. 组件代码骨架

### 3.1 WebView + xterm.js(UI 层)

文件:`app/src/main/assets/terminal.html`

```html
<!doctype html>
<html><head>
  <link rel="stylesheet" href="xterm.css">
  <style>
    body { margin: 0; background: #11131a; }
    #term { height: 100vh; }
    #voice-overlay {
      position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%);
      background: rgba(20, 22, 30, 0.95); backdrop-filter: blur(20px);
      padding: 16px 24px; border-radius: 12px; color: #e6e6e6;
      font-family: 'JetBrains Mono', monospace; min-width: 360px;
      box-shadow: 0 10px 40px rgba(0,0,0,0.5); display: none;
    }
  </style>
</head><body>
  <div id="term"></div>
  <div id="voice-overlay">
    <div id="overlay-status">🎤 录音中...</div>
    <div id="overlay-text" style="margin-top: 8px; color: #94e0b2;"></div>
    <div style="margin-top: 12px; font-size: 12px; color: #888;">
      Enter 发送 · Esc 撤销
    </div>
  </div>
  <script src="xterm.js"></script>
  <script src="addon-fit.js"></script>
  <script src="addon-webgl.js"></script>
  <script src="addon-search.js"></script>
  <script>
    const term = new Terminal({
      fontFamily: '"JetBrains Mono", monospace', fontSize: 14, lineHeight: 1.2,
      theme: { background: '#11131a', foreground: '#e6e6e6', cursor: '#94e0b2' },
      cursorBlink: true, scrollback: 10000,
    });
    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.loadAddon(new WebglAddon.WebglAddon());
    term.loadAddon(new SearchAddon.SearchAddon());
    term.open(document.getElementById('term'));
    fitAddon.fit();

    // 用户敲键 → Kotlin
    term.onData(data => Bridge.onInput(btoa(data)));
    term.onResize(({cols, rows}) => Bridge.onResize(cols, rows));

    // 提供给 Kotlin 调用的 API
    window.writeToTerm = (b64) =>
      term.write(Uint8Array.from(atob(b64), c => c.charCodeAt(0)));
    window.showOverlay = (status, text) => {
      document.getElementById('overlay-status').innerText = status;
      document.getElementById('overlay-text').innerText = text || '';
      document.getElementById('voice-overlay').style.display = 'block';
    };
    window.hideOverlay = () =>
      document.getElementById('voice-overlay').style.display = 'none';
  </script>
</body></html>
```

assets 目录需要的文件(从 npm 包拷过来):
- `xterm.js` / `xterm.css`(v5.5+)
- `addon-fit.js`(v0.10+)
- `addon-webgl.js`(v0.18+)
- `addon-search.js`(v0.15+ — 支持 Ctrl+F 搜 scrollback)

### 3.2 SSH 模块(sshj 0.39+)

文件:`app/src/main/kotlin/.../SshConnection.kt`(实现 `PtyChannel` 接口)

> **现状**:下面是骨架起点。真实代码已演进出几个关键点(以真实代码为准):
> - **写入永远异步**:`write/resize` 入队到单线程 `ssh-io` executor。**绝不在主线程写 socket** —— `dispatchKeyEvent`(硬件 Enter/方向键、语音注入)在主线程,直接 flush 会抛 `NetworkOnMainThreadException`,且 sshj `ChannelOutputStream.flush` 异常非安全,一次就把 channel 缓冲永久写坏(memory `input-path-constraints`)。
> - **host key 验证**:`knownHostsFile != null` → `TofuKnownHosts`(TOFU 持久化);null → `PromiscuousVerifier`(仅测试 / 多跳终点)。
> - **多跳**:`jump: JumpSpec?` 非空 → 先建 `SshJump` 转发,真正连 `127.0.0.1:<localPort>`(见 §3.2.1)。
> - `connectTimeout` 12s(VPN 掉线时 socket 不会无限挂死)。

```kotlin
class SshConnection(
    private val host: String,
    private val port: Int = 22,
    private val user: String,
    private val privateKeyPath: String,
    private val startupCommand: String = "abduco -A dev bash",  // agent 类传 "tmux new -A -s <s>"
    private val knownHostsFile: File? = null,                   // null=Promiscuous,非空=TOFU
    private val jump: JumpSpec? = null,                         // 非空=经跳板 ProxyJump
) : PtyChannel {
    private var client: SSHClient? = null
    private var channel: Session.Command? = null
    private var sshJump: SshJump? = null
    // 所有网络 I/O 丢到这个单线程(绝不在主线程写 socket)
    private val ioExec = Executors.newSingleThreadExecutor { r -> Thread(r, "ssh-io").apply { isDaemon = true } }

    fun connect(cols: Int, rows: Int) {
        Crypto.ensureFullBouncyCastle()   // X25519 KEX 需完整 BC
        val (cHost, cPort, verifier) = if (jump != null) {
            val j = SshJump.open(jump, host, port).also { sshJump = it }
            Triple("127.0.0.1", j.localPort, PromiscuousVerifier())  // 终点 host key 无法 TOFU
        } else Triple(host, port, knownHostsFile?.let { TofuKnownHosts(it) } ?: PromiscuousVerifier())
        val c = SSHClient().apply {
            connectTimeout = 12_000
            addHostKeyVerifier(verifier); connect(cHost, cPort); authPublickey(user, privateKeyPath)
        }
        val cmd = c.startSession().apply { allocatePTY("xterm-256color", cols, rows, 0, 0, emptyMap()) }
            .exec(startupCommand)   // exec 而非 startShell:入口直接是 abduco/tmux
        client = c; channel = cmd
    }

    override fun inputStream() = checkNotNull(channel).inputStream
    override fun write(data: ByteArray) {                          // fire-and-forget,顺序由单线程保证
        val ch = channel ?: return
        ioExec.execute { runCatching { ch.outputStream.write(data); ch.outputStream.flush() } }
    }
    override fun resize(cols: Int, rows: Int) { /* changeWindowDimensions 也走 ioExec */ }
    override fun close() { ioExec.shutdownNow(); runCatching { channel?.close(); client?.disconnect(); sshJump?.close() } }
}
```

#### 3.2.1 多跳 SSH(ProxyJump)

文件:`app/src/main/kotlin/.../SshJump.kt`

OPS 在 AWS 内网,只 VPN 可达。`SshJump.open(spec, targetHost, targetPort)` 用 sshj 的 `LocalPortForwarder`:先连跳板 TK,把 `127.0.0.1:<系统分配口>` 转发到 `OPS:22`,返回 `localPort`。调用方(`SshConnection` / `HostClient`)把真正的 SSHClient 连到这个本地口 ——**认证端到端打到 OPS,跳板只转发 TCP**。`HostConfig.via = "TK-ALIYUN"` 触发这条路径;`StatusPoller`/`ManifestFetcher` 解析 `via` 拼出 `JumpSpec`。VPN(OpenVPN→AWS Client VPN)挂在 TK 上,手机不挂。

`build.gradle.kts` 依赖:

```kotlin
dependencies {
    implementation("com.hierynomus:sshj:0.39.0")
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
    implementation("net.i2p.crypto:eddsa:0.3.0")
    // ... 其他见 §6 依赖清单
}
```

**Fallback**:如 sshj 在 Beam Pro 上有 BouncyCastle 问题(Stage A.2 验),换 [sshlib (ConnectBot)](https://github.com/connectbot/sshlib) — 同样的 connect/session/PTY 概念,API 不同需要 wrapper 适配。

### 3.3 JSBridge(双向桥接)

文件:`app/src/main/kotlin/.../TerminalBridge.kt`

```kotlin
class TerminalBridge(private val ch: PtyChannel) {   // 持 PtyChannel(SshConnection / LocalEchoChannel)
    @JavascriptInterface
    fun onInput(b64: String) {
        ch.write(Base64.decode(b64, Base64.NO_WRAP))   // 异步,内部入队到 ssh-io 线程
    }
    @JavascriptInterface
    fun onResize(cols: Int, rows: Int) { ch.resize(cols, rows) }
}
```

Activity 中 wire 起来:

```kotlin
webView.addJavascriptInterface(TerminalBridge(ssh), "Bridge")
webView.settings.javaScriptEnabled = true
webView.loadUrl("file:///android_asset/terminal.html")

// 后台线程:SSH 输出 → WebView
thread {
    val buf = ByteArray(4096)
    while (true) {
        val n = ssh.inputStream().read(buf); if (n <= 0) break
        val b64 = Base64.encodeToString(buf.copyOf(n), Base64.NO_WRAP)
        runOnUiThread { webView.evaluateJavascript("writeToTerm('$b64')", null) }
    }
}
```

**Base64 性能**:对 SSH < 100 KB/s 输出无感。如果 Stage A.3 发现 60fps 大输出(`top` 等)卡顿,fallback 到 localhost WebSocket(Kotlin 起一个 127.0.0.1:0 server,WebView 内 JS 用 WebSocket 连),~30 行代码切换。

### 3.4 Voice Daemon

文件:`app/src/main/kotlin/.../VoiceDaemon.kt`

```kotlin
class VoiceDaemon(
    private val webView: WebView,
    private val ssh: SshConnection,
    private val asr: AsrClient,  // 豆包封装
    private val mainHandler: Handler
) {
    enum class State { IDLE, RECORDING, ASR_PENDING, PREVIEW }
    private var state = State.IDLE
    private var currentText: String? = null
    private var recorder: AudioRecord? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    fun onKeyDown(keyCode: Int) {
        if (keyCode == KEY_F13 || keyCode == KEY_F14) {
            val lang = if (keyCode == KEY_F13) "zh" else "en"
            // 任意状态下按 F13/F14 都是"开始(重新)录音"
            if (state == State.PREVIEW || state == State.RECORDING) hideOverlay()
            startRecording(lang)
            state = State.RECORDING
            showOverlay("🎤 录音中...", "")
        }
    }
    fun onKeyUp(keyCode: Int) {
        if ((keyCode == KEY_F13 || keyCode == KEY_F14) && state == State.RECORDING) {
            val audio = stopRecording()
            state = State.ASR_PENDING
            showOverlay("识别中...", "")
            scope.launch {
                val text = asr.recognize(audio)
                currentText = text
                state = State.PREVIEW
                showOverlay("🎤 已识别", text)
            }
        }
    }
    fun onEnter(): Boolean {  // return true = 拦截,false = 透传到 WebView
        if (state == State.PREVIEW) {
            val text = currentText ?: return false
            ssh.outputStream().write(text.toByteArray()); ssh.outputStream().flush()
            hideOverlay(); state = State.IDLE; currentText = null
            return true
        }
        return false
    }
    fun onEsc(): Boolean {
        if (state != State.IDLE) {
            stopRecording(); hideOverlay()
            state = State.IDLE; currentText = null
            return true
        }
        return false
    }

    private fun showOverlay(status: String, text: String) {
        val s = JSONObject.quote(status); val t = JSONObject.quote(text)
        mainHandler.post { webView.evaluateJavascript("showOverlay($s, $t)", null) }
    }
    private fun hideOverlay() {
        mainHandler.post { webView.evaluateJavascript("hideOverlay()", null) }
    }

    private fun startRecording(lang: String) { /* AudioRecord.start + 缓存 lang */ }
    private fun stopRecording(): ByteArray { /* AudioRecord.stop + 返回 buffer */ }

    companion object {
        // 内部状态机仍用 F13/F14 区分语言通道;真实硬件入口是 F1(见 §3.5)经 onKeyDown(KEY_F13)调进来
        const val KEY_F13 = 326
        const val KEY_F14 = 327
    }
}
```

> **现状**:`asr` 实现已是真豆包流式 ASR `VolcEngineAsr`(WebSocket 双向流式,边录边传中间结果,见 `VolcEngineAsr.kt`/`VolcFrame.kt`);项目级热词经 `Hotwords` 合并喂 ASR。Phase 0 的 mock ASR 仅历史阶段用。语音注入对 AI-agent project 会加 🎤 marker(给 sub-agent 识别),SSH 配角终端不加。

### 3.5 按键路由(Activity 顶层)

文件:`app/src/main/kotlin/.../MainActivity.kt`(片段)

> **键位实测改定(2026-05-29 Stage A.1)**:8BitDo 在 Beam Pro 走 `Generic.kl`,F13–F24 被注释 → 326/327 **到不了 app**。主路径改用 **F1=语音(hold-to-talk)、F2=返回列表**(`KEYCODE_F1/F2`);F13/F14 代码分支留作其它设备兜底,虚拟语音键经 bridge 直接调 `onKeyDown/onKeyUp`。详见 README「操作」+ memory `beam-pro-device`。

```kotlin
override fun dispatchKeyEvent(event: KeyEvent): Boolean {
    when (event.keyCode) {
        KeyEvent.KEYCODE_F1 -> {                       // 主路径:语音(hold-to-talk)
            if (event.action == KeyEvent.ACTION_DOWN) voiceDaemon.onKeyDown(VoiceDaemon.KEY_F13)
            else if (event.action == KeyEvent.ACTION_UP) voiceDaemon.onKeyUp(VoiceDaemon.KEY_F13)
            return true
        }
        KeyEvent.KEYCODE_F2 -> { if (event.action == KeyEvent.ACTION_DOWN) returnToList(); return true }  // 返回列表
        KeyEvent.KEYCODE_ENTER -> {
            if (event.action == KeyEvent.ACTION_DOWN && voiceDaemon.onEnter()) return true
        }
        KeyEvent.KEYCODE_ESCAPE -> {
            if (event.action == KeyEvent.ACTION_DOWN && voiceDaemon.onEsc()) return true
        }
    }
    return super.dispatchKeyEvent(event)
}
```

逻辑:F1 永远给 Voice Daemon(hold-to-talk);F2 返回 project 列表;Enter/Esc 给 Voice Daemon **如果它在使用 overlay**,否则透传到 WebView → xterm.js → SSH。

### 3.6 Agent 状态展示(hooks 事件驱动,**非抓屏**)

文件:服务端 `docs/xreal-project.sh`(部署)+ `app/.../ManifestFetcher.kt`(读取)+ `StatusPoller.staticListJson`(并入列表)。

列表卡片上的 working/waiting/disconnected 状态走 **Claude Code hooks**,不是周期性抓屏:

```
Claude Code 事件          hook 写入                          app 显示
─────────────────────────────────────────────────────────────────────
UserPromptSubmit  ──┐
Stop              ──┤  agent-status.sh <session> <state>   ManifestFetcher.fetch()
SessionStart      ──┤    → .xreal/status/<session>.json     一次性 cat .xreal/status.json
SessionEnd        ──┘    → 聚合 .xreal/status.json          → SessionState(state, since)
(UserPromptSubmit→working / Stop→waiting / SessionEnd→disconnected;
 状态不变保留 since,客户端据此算时长)
```

- `xreal-project.sh new`(建项目)/ `hooks`(批量铺开)时,对 agent 类 project 自动 `deploy_status_hooks`:写 `agent-status.sh` + 把这几个事件 merge 进 `<dir>/.claude/settings.json`(python merge,保留用户已有 hook)。session 名烤进 hook 命令,运行时零识别。
- app 端不轮询屏幕:`ManifestFetcher` 拉 `projects.json` 时**同连接顺手 cat `status.json`**,缺失/坏 → 该 session 判 **unknown**(用户拍板:不清楚就 unknown,不抓屏兜底)。host cat 不到 manifest → 整 host 判 disconnected。
- **抓屏方案已搁置**:`AgentStatusDetector`(解析 `tmux capture-pane -p`)+ `StatusPoller`(5s 轮询)+ `HostClient.captureAll` 仍在代码里,但由 `FleetFeatures.LIVE_STATUS = false` 关掉(留作回退 / 历史)。现行实时状态 = hooks。

### 3.7 其它本期落地组件

- **`PtyChannel` 接口** + `LocalEchoChannel`:终端写入抽象。`SshConnection` 是真实现;`LocalEchoChannel` 给未连接时本地回显。`TerminalBridge`/`VoiceDaemon` 都持 `PtyChannel`,热切 channel 不重建 WebView。
- **`AppLog` + `XrealApp`**(持久化日志 + 崩溃捕获):眼镜上闪退、手机没接 adb 时,崩溃栈/断连上下文全丢。`XrealApp`(Application 子类)进程一起来就 `AppLog.init` + 装全局未捕获异常处理器,后台线程(ssh-io / pty-reader / ASR WS reader)崩溃时同步直写 `getExternalFilesDir("logs")/app.log`,并在下次启动把上一会话尾部重喷 logcat(tag `AppLogPrev`)。
- **tmux 体验**:agent 类启动命令是 `tmux -u -f <conf> new -A -s <session>`,conf 用 base64 投递,设 `history-limit 50000` + S-Up/S-Down 半页翻页(`copy-mode halfpage-up/down`)。见 `MainActivity.tmuxAttachCommand`。
- **虚拟键盘动态显隐 + 列表加载态**(WebView 侧 UI):首屏冷加载状态徽章转圈,manifest 拉到后变真状态。

---

## 4. 7 个关键技术决策(摘要)

详细 trade-off 见上游 `docs/07-android-app-architecture.md §7`。这里只摘要"为什么是它"。

| # | 决策 | 选了什么 | 为什么 |
|---|---|---|---|
| 1 | 单 app vs 多 app | **单 app** | 消除跨 App 文本注入难题 |
| 2 | WebView+xterm.js vs Compose terminal | **WebView+xterm.js** | xterm.js 5+ 年沉淀,WebGL 60fps,UI 完全可控 |
| 3 | SSH 库 | **sshj 主推,sshlib fallback** | sshj API 现代,sshlib 是 Android 兜底 |
| 4 | JSBridge 编码 | **Base64 主推,localhost WS fallback** | Base64 对 SSH KB/s 足够,WS 在大输出场景兜底 |
| 5 | Overlay | **WebView 内 HTML 元素** | 零权限,零跨 App,零 SYSTEM_ALERT_WINDOW |
| 6 | Voice 注入路径 | **直写 SSH outputStream** | Voice Daemon 不需要知道 xterm.js 存在 |
| 7 | 服务端 session 驻留 | **agent 类 tmux,纯 SSH 可 abduco** | 升级成 agent 指挥台后,状态/翻页需要 tmux;纯 SSH 仍可 abduco,见 [`session-persistence-options.md`](session-persistence-options.md) |
| 8 | Agent 状态来源 | **Claude Code hooks(非抓屏)** | 事件驱动,准、省,零 5s 轮询;抓屏方案搁置(见 §3.6) |
| 9 | OPS(内网 host)接入 | **多跳 ProxyJump(经 TK)** | VPN 挂 TK,手机不挂;认证端到端到 OPS(见 §3.2.1) |

---

## 5. 失败模式与降级

| 故障 | 检测 | 体感 | 恢复 |
|---|---|---|---|
| 豆包 ASR 错(高频)| overlay 文本明显不对 | 一眼看清 | **按 Esc 撤销** — SSH 永不收到错的字符 |
| 豆包 API 失败 | WS 非正常关 / 错误帧 | overlay 显示"ASR 失败" | F1 重试 / Esc 取消 |
| SSH 断 | sshj 抛 IOException(connectTimeout 12s 兜底)| xterm.js 显示 "Disconnected" | 自动重连;tmux session 不丢 |
| 蓝牙断 | InputDevice 拔出事件 | 按键无响应 | 状态栏 notification + 自动重连 |
| WebView crash | uncaught exception | terminal 空白 | Activity 重建 WebView,SSH 不断 |
| App 整个挂 | — | 都不响应 | **任何 SSH client 都能直连服务器继续工作** |

---

## 6. 依赖清单

`build.gradle.kts`(Module: app):

```kotlin
android {
    compileSdk = 35  // Android 15
    defaultConfig {
        minSdk = 34  // Android 14 (Beam Pro)
        targetSdk = 35
    }
}
dependencies {
    // SSH
    implementation("com.hierynomus:sshj:0.39.0")
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
    implementation("net.i2p.crypto:eddsa:0.3.0")

    // UI
    implementation("androidx.activity:activity-ktx:1.9.0")
    implementation("androidx.webkit:webkit:1.11.0")
    implementation("androidx.core:core-ktx:1.13.0")

    // 网络 & 序列化(豆包 ASR REST 调用)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.json:json:20240303")

    // Audio
    implementation("io.github.lostromb.concentus:concentus:1.1.1")  // Opus

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
}
```

`assets/` 静态:
- `xterm.js` + `xterm.css`(v5.5+,~500KB)
- `addon-fit.js` v0.10+
- `addon-webgl.js` v0.18+
- `addon-search.js` v0.15+
- 可选 `addon-unicode11.js` v0.8+(CJK 宽字符精确对齐)

预期 APK 增量:**8-12 MB**。

---

## 7. 总结

§3 的代码骨架早已落地,真机(Beam Pro X4100)在跑:真 SSH(含多跳 ProxyJump)、xterm.js 终端、豆包流式语音、Maestro 编排的多 host/project、Agent 状态展示(hooks)。Stage A 三个架构风险实验已在真机闭环(见 `stage-a-experiments.md`)。本文档的骨架是设计参考,**实际实现以 `android/app/src/main/kotlin/.../` 真实代码为准**(已有出入处文中已加「现状」注)。
