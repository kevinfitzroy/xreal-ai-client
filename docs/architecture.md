# 架构详解 + 可编译代码骨架

> 这份文档是从上游 `term-on-demand` 仓库的 `docs/07-android-app-architecture.md` 摘出 + 针对实施需要做了一些补充的版本。所有代码骨架都是 **可编译起点**,不是教学伪代码。

---

## 1. 设计原则(必须遵守)

1. **单 Android App 闭环** — SSH 协议 / 终端渲染 / 按键事件 / 录音 / ASR / overlay,全部在一个 APK 内。无跨 App 通信、无 IME 注入、无 Accessibility,无 `SYSTEM_ALERT_WINDOW`
2. **零服务端增量** ⭐ — 服务端只跑用户已有的 shell + `claude code`。无 ttyd、无 nginx、无 Voice Gateway。从服务端运维角度,本 App 跟普通 SSH client 没区别
3. **UI 完全 WebView 实现** — terminal 用 xterm.js,候选/状态 overlay 是 WebView 里的 HTML 元素。Android 端只管 SSH 字节流 + 按键事件 + 音频
4. **Voice 直写 SSH channel,跳过 xterm.js** — Voice Daemon 拿到 ASR 文本后**直接写 SSH 输出流**,字符通过 shell echo 在远端回显,xterm.js 渲染 — Voice Daemon 不需要知道 xterm.js 存在
5. **优雅降级** — App 挂了,任何 SSH client 都能继续工作。App 是体验增强,不是必需品
6. **服务端 session 驻留用 abduco,不是 tmux** — 详见 [`session-persistence-options.md`](session-persistence-options.md)。`SshConnection` 把启动命令做成可配置

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
                 ▼
       服务器(海外 Ubuntu)
       └─ abduco -A dev claude code --resume
       (无 ttyd / 无 nginx / 无 Voice Gateway)
```

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

文件:`app/src/main/kotlin/.../SshConnection.kt`

```kotlin
class SshConnection(
    private val host: String,
    private val port: Int,
    private val user: String,
    private val privateKeyPath: String,
    private val startupCommand: String = "abduco -A dev bash"  // 可配置,见 session-persistence-options.md
) {
    private lateinit var client: SSHClient
    private lateinit var session: Session
    private lateinit var shell: Session.Shell

    fun connect(cols: Int, rows: Int) {
        client = SSHClient(DefaultConfig()).apply {
            addHostKeyVerifier(OpenSSHKnownHosts(File("$filesDir/known_hosts")))
            connect(host, port)
            authPublickey(user, privateKeyPath)
        }
        session = client.startSession().apply {
            allocatePTY("xterm-256color", cols, rows, 0, 0, emptyMap())
        }
        // 用 exec 而不是 startShell — exec 可以直接传 startup 命令
        shell = session.exec(startupCommand) as Session.Shell
    }

    fun outputStream(): OutputStream = shell.outputStream
    fun inputStream(): InputStream = shell.inputStream

    fun resize(cols: Int, rows: Int) {
        session.changeWindowDimensions(cols, rows, 0, 0)
    }

    fun disconnect() {
        runCatching { shell.close(); session.close(); client.disconnect() }
    }
}
```

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
class TerminalBridge(private val ssh: SshConnection) {
    @JavascriptInterface
    fun onInput(b64: String) {
        val bytes = Base64.decode(b64, Base64.NO_WRAP)
        ssh.outputStream().write(bytes)
        ssh.outputStream().flush()
    }
    @JavascriptInterface
    fun onResize(cols: Int, rows: Int) { ssh.resize(cols, rows) }
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
        // KEYCODE_F13 = 326 (API 36 公开常量,raw int 跨版本可用)
        const val KEY_F13 = 326
        const val KEY_F14 = 327
    }
}
```

**Stage 0.6 中 Voice Daemon 用 mock ASR**(返回固定字符串,不接豆包),验证状态机 + overlay 显隐 + Enter 写 SSH 路径。Stage B 才真正接豆包 SDK。

### 3.5 按键路由(Activity 顶层)

文件:`app/src/main/kotlin/.../MainActivity.kt`(片段)

```kotlin
override fun dispatchKeyEvent(event: KeyEvent): Boolean {
    when (event.keyCode) {
        VoiceDaemon.KEY_F13, VoiceDaemon.KEY_F14 -> {
            if (event.action == KeyEvent.ACTION_DOWN) voiceDaemon.onKeyDown(event.keyCode)
            else if (event.action == KeyEvent.ACTION_UP) voiceDaemon.onKeyUp(event.keyCode)
            return true  // 不传给 WebView
        }
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

逻辑:F13/F14 永远给 Voice Daemon;Enter/Esc 给 Voice Daemon **如果它在使用 overlay**,否则透传到 WebView → xterm.js → SSH。

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
| 7 | 服务端 session 驻留 | **abduco**(不是 tmux) | 零 UI 零卡顿,xterm.js 客户端有 scrollback,见 [`session-persistence-options.md`](session-persistence-options.md) |

---

## 5. 失败模式与降级

| 故障 | 检测 | 体感 | 恢复 |
|---|---|---|---|
| 豆包 ASR 错(高频)| overlay 文本明显不对 | 一眼看清 | **按 Esc 撤销** — SSH 永不收到错的字符 |
| 豆包 API 失败 | HTTP 非 200 | overlay 显示"ASR 失败" | F13 重试 / Esc 取消 |
| SSH 断 | sshj 抛 IOException | xterm.js 显示 "Disconnected" | 自动重连;abduco session 不丢 |
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

按 §3 给的代码骨架顺序实现,Phase 0 一个 emulator-runnable 的 APK 应该在 1-2 天内出来。剩下的时间用来 polish UI 和 mock Voice Daemon 路径。Stage A 真机验证留给 Phase 1。
