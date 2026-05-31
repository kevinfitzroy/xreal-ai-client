# Stage A:3 个实验决定 80% 架构风险

> Phase 0 写的代码,拿到物理设备后跑这 3 个实验决定整个架构是否成立。每个实验有 named fallback。
>
> **现状(2026-05,Beam Pro X4100 真机)**:三个实验都已在真机上验过 —— A.1 ✅(假设 FAIL,已切 F1/F2 预案)、A.2 ✅(隐含通过)、A.3 🟡(功能通过,正式压测未跑)。详见各节顶部状态条 + 文末「通过判据总结」。下文各节正文为原始实验设计,留作记录。

---

## A.1(1 天)8BitDo Micro F13/F14 在 Android 14 上的 keycode 实测

> ✅ **已执行(2026-05-29,Beam Pro 真机)— 假设 FAIL,已切 Fallback**:`getevent` 能看到 8BitDo Keyboard 子设备正确发出 `KEY_F13`,但 Beam Pro 的 `/system/usr/keylayout/Generic.kl` 里 **`F13`–`F24`(scancode 183+)全被 `#` 注释** → Android 映射不出 keycode,在送达 `dispatchKeyEvent` *之前*丢弃(连 keycode 0 都不给)。`/system` 只读、无 root,改不了。**`F1`–`F12` 在 Generic.kl 活跃**(→ `KEYCODE_F1`=131…)→ 主路径改用 **F1=语音(hold-to-talk)/ F2=返回列表**(避开 F5/F11/F12 被 WebView 拦截),真机端到端验证 F1 触发真豆包 ASR。代码里 F13/F14/F15 分支保留作其它设备兜底,Ctrl+Alt+1/2 备路径仍可用。下文为原始实验设计,留作记录。

### 假设要验证

8BitDo Ultimate Software 官方支持 F13-F24,且 Android 14 通过蓝牙 HID 能正确接收为 `KEYCODE_F13` (= 326) / `KEYCODE_F14` (= 327)。

### 做什么

1. 用 [8BitDo Ultimate Software](https://app.8bitdo.com/Ultimate-Software-V2/) 把 8BitDo Micro 两个按键(比如 ZL、ZR 肩键)配成 F13、F14
2. Beam Pro / 任意 Android 14 设备 蓝牙配对 8BitDo Micro
3. 装 Phase 0 写的最小 App(或者临时一个 Activity)
4. 在 `dispatchKeyEvent` 里 log 所有按键:
   ```kotlin
   override fun dispatchKeyEvent(event: KeyEvent): Boolean {
       Log.d("KEY", "keyCode=${event.keyCode} action=${event.action} scanCode=${event.scanCode} device=${event.device?.name}")
       return super.dispatchKeyEvent(event)
   }
   ```
5. 用 `adb logcat | grep KEY` 看输出,按 8BitDo 的两个键

### Pass 判据

- 按 F13 物理键 → log 显示 `keyCode=326`
- 按 F14 物理键 → log 显示 `keyCode=327`
- KeyDown 和 KeyUp 都正确触发

→ **主路径成立**,Phase 0 的 `VoiceDaemon.KEY_F13 = 326` 设计无修改

### Fail 判据 + Fallback

可能的 fail 模式:
- log 显示 `keyCode=0`(UNKNOWN)或某个其他奇怪的值
- 只有 KeyDown 没有 KeyUp(8BitDo 固件 bug)
- Android 14 把 F13 mapping 到了其他东西

**Fallback A**:8BitDo 改配 **Ctrl+Alt+1** / **Ctrl+Alt+2** 组合键
- 这两个组合 8BitDo 必支持(普通字母 + 修饰键)
- Android 必收到(`KEYCODE_1` + meta 状态)
- `VoiceDaemon` 改成检测 `KEYCODE_1` + `metaState & (META_CTRL_ON | META_ALT_ON)`,语义不变
- 代价:用户在普通 App 里如果用 Ctrl+Alt+1(罕见,但比如某些 IDE 的"切到 tab 1")会冲突 — 只在本 App 里有效,出 App 不冲突

**Fallback B**:用 8BitDo 的"游戏手柄"模式而不是"键盘"模式
- 此时按键发的是 `KEYCODE_BUTTON_L1` / `BUTTON_R1` 等
- Android 完整支持手柄事件,不冲突任何键盘
- 代价:跨平台 ABI 差异更大(不同手柄 button 编号不同)

---

## A.2(2 天)sshj 0.39+ 在 Android 14 上的 BouncyCastle 实战

> ✅ **已隐含通过(2026-05,Beam Pro 真机)**:sshj `SSHClient` + `Crypto.ensureFullBouncyCastle()`(X25519 KEX 需完整 BC)在真机上连通海外 host(TK-ALIYUN)+ 经跳板多跳到内网 host(OPS via ProxyJump),终端端到端跑通,`connect/authPublickey/PTY/resize` 均无异常。**没出现 `NoClassDefFoundError` / 算法不支持**,主路径成立,无需切 sshlib(`SshConnection` 仍保留可切换抽象)。下文为原始实验设计,留作记录。

### 假设要验证

sshj 0.39+(经过 PR #636 等多轮修复)在 Android 14 / Beam Pro 的 NebulaOS 上,BouncyCastle 注册和加密协议都能正常工作。

### 做什么

1. 准备一台可 SSH 的服务器,authorized_keys 加测试公钥
2. 空 Android Studio 项目(API 34,Kotlin):
   ```kotlin
   class MainActivity : AppCompatActivity() {
       override fun onCreate(savedInstanceState: Bundle?) {
           super.onCreate(savedInstanceState)
           // 简单 UI:EditText 输入命令,Button 执行,TextView 显示输出
           Thread {
               val client = SSHClient(DefaultConfig()).apply {
                   addHostKeyVerifier(PromiscuousVerifier())  // 测试阶段
                   connect("YOUR_SERVER", 22)
                   authPublickey("user", "/sdcard/test_id_rsa")
               }
               val session = client.startSession()
               session.allocatePTY("xterm-256color", 80, 24, 0, 0, emptyMap())
               val shell = session.startShell()
               // 写 "ls -la\n" 并读输出
               shell.outputStream.write("ls -la\n".toByteArray())
               shell.outputStream.flush()
               Thread.sleep(500)
               val available = shell.inputStream.available()
               val buf = ByteArray(available)
               shell.inputStream.read(buf)
               Log.d("SSH", String(buf))
           }.start()
       }
   }
   ```
3. 实测以下命令:`ls / vim / less / Ctrl+C(写 0x03) / Ctrl+D(写 0x04)`
4. 测 PTY resize:`session.changeWindowDimensions(120, 40, 0, 0)` 后 `stty size` 看是否生效

### Pass 判据

- `connect / authPublickey` 都不抛异常
- 基本命令(ls/vim/less)能跑通,输出正确
- Ctrl+C 能中断当前命令
- PTY resize 后 `stty size` 反映新尺寸

→ **主路径成立**,sshj 是 Phase 0 SSH 库选择

### Fail 判据 + Fallback

可能的 fail 模式:
- `NoClassDefFoundError: org.bouncycastle.*` — BouncyCastle 加载失败
- `Algorithm not supported` — 某个 key exchange 算法 NebulaOS 不支持
- SSH 握手卡住 / 超时

**Fallback A**:[sshlib (ConnectBot)](https://github.com/connectbot/sshlib)
- 专为 Android 维护,无 BouncyCastle 依赖
- API 稍老(基于 trilead-ssh2),需要写个 adapter wrapper
- 代码骨架:
  ```kotlin
  // sshlib 用法略不同
  val conn = Connection("YOUR_SERVER", 22)
  conn.connect()
  conn.authenticateWithPublicKey("user", File("/sdcard/test_id_rsa"), null)
  val session = conn.openSession()
  session.requestPTY("xterm-256color", 80, 24, 0, 0, null)
  session.startShell()
  // 流通过 session.stdout / session.stdin / session.stderr
  ```
- Phase 0 的 `SshConnection` 抽象设计要预留接口,fail 时能在两个实现间切换

**Fallback B**:[Apache MINA SSHD client](https://mina.apache.org/sshd-project/)
- 也成熟,代码量比 sshj 大
- 备选,通常 sshlib 已经足够

---

## A.3(2 天)WebView + xterm.js + JSBridge 全栈端到端

> 🟡 **功能层已通过,性能未正式基准(2026-05,Beam Pro 真机)**:WebView + xterm.js + Base64 JSBridge 端到端跑通真 SSH 终端 —— 键盘/语音输入进 SSH、输出回流、中英文 + powerline + emoji(unicode11 addon)正确渲染、PTY resize 同步、Ctrl+C 中断、tmux copy-mode 翻页都正常,日常 Claude Code TUI 体感流畅。**尚未跑「`top` 5s+ 稳定 30fps」「50000 行 cat 5s 内不冻 UI」这两条正式压测**,故标 🟡;主路径已可用,正式基准 + WebGL renderer 确认留待需要时补。下文为原始实验设计。

### 假设要验证

xterm.js + WebGL renderer 在 Beam Pro 的 Snapdragon 7 Gen 2 GPU 上能流畅(60fps)处理大量输出(如 `top`、`htop`、`cat large.log`),并且 Base64 over `evaluateJavascript` 的 JSBridge 在这种吞吐下不卡。

### 做什么

合并 A.1(可选)+ A.2,加 WebView 层:

1. WebView 加载 `assets/terminal.html`(架构文档 §3.1 那个骨架)
2. JSBridge 双向连接(架构文档 §3.3 骨架)
3. Activity 启动时 SSH 连接(用 A.2 验证过的代码),把 inputStream 推 WebView,把 WebView onData 写 SSH outputStream
4. 实测场景:
   - 在 WebView 里按键,远端 shell 收到字符(用 `cat` 看)
   - `ls / vim / less large.log / top` — 检查渲染流畅度
   - `cat /path/to/file_50000_lines` — 大量输出冲击 JSBridge
   - PTY resize 同步(WebView 改 fit 后,远端 `stty size` 是否对)
   - Ctrl+C 是否中断
   - 中文 / 表情符 / 宽字符是否正确渲染

### Pass 判据

- `top` 在 5 秒以上稳定 30fps+(肉眼无卡顿)
- 50000 行 cat 输出在 5 秒内完成,期间 UI 不冻
- PTY resize 后命令行 wrap 正常
- 中文 / emoji / box-drawing 字符正确
- Ctrl+C 中断生效

→ **整个架构 proven** — Phase 0 全过,Phase 1 只是堆体验(Voice Daemon、主题、稳定性)

### Fail 判据 + Fallback

可能 fail 点:

**Fail 1**:JSBridge Base64 在 60fps 大输出下出现明显卡顿(渲染落后输入 1s+)
- **Fallback**:切到 **localhost WebSocket**
  - Kotlin 起一个 `127.0.0.1:0`(随机端口)WebSocket server
  - WebView 内 JS 用 `new WebSocket('ws://127.0.0.1:PORT')` 连
  - 二进制帧直传,零编码开销
  - ~30 行代码增量
- 实测后大概率不需要,但作为兜底

**Fail 2**:WebGL renderer 在 Snapdragon 7 Gen 2 GPU 上崩 / 渲染错乱
- **Fallback**:退回 xterm.js 默认 Canvas renderer
  - 把 `term.loadAddon(new WebglAddon.WebglAddon())` 这一行删掉即可
  - Canvas 比 WebGL 慢但更稳

**Fail 3**:中文 / IME 输入有问题
- 可能是 `term.onData` 没正确处理 composing state
- 实测中:用 Android 系统输入法在 WebView 里输中文,看是否字符正确进 SSH
- Fallback:Activity 层捕获 IME 事件,手动转发到 `term.input(text)`

**Fail 4**:PTY resize 不同步
- sshj 的 `changeWindowDimensions` 没生效?
- 实测 `stty size` 在 WebView resize 后是否对
- Fallback:每次 resize 后 `shell.outputStream.write("export COLUMNS=$cols\n".toByteArray())` 手动通告

---

## 通过判据总结

| Stage A | 现状(2026-05,Beam Pro 真机)|
|---|---|
| **A.1** 8BitDo 物理键 | ✅ 已实测,假设 FAIL → 切 Fallback:主路径改 **F1/F2**(F13/F14 在 `Generic.kl` 被注释,到不了 app),端到端验过真豆包 ASR |
| **A.2** sshj / BouncyCastle | ✅ 隐含通过:真机连通海外 host + 多跳到内网 host,无 BC/算法异常,无需切 sshlib |
| **A.3** WebView + xterm GPU | 🟡 功能通过(终端 + 中英 + powerline + emoji + 翻页 + resize 全正常),正式 60fps/大输出压测未跑 |

三个实验主路径均已成立(A.1 走的是预案 Fallback,A.2/A.3 走主路径),架构已进入「堆体验 + 稳定性」阶段(语音、状态展示、多跳、日志均已落地)。每个实验仍保留 fallback 接口(sshj↔sshlib、WebGL↔Canvas、Base64↔WebSocket),对单点失效 robust。

---

## 时间预算

- A.1 — 1 天(2 小时配 8BitDo + 4 小时 Android Studio 项目 + 2 小时调试)
- A.2 — 2 天(1 天搭项目 + 1 天调通 sshj / 看错误日志 / 如果需要切 sshlib)
- A.3 — 2 天(1 天 wire 起来 + 1 天 polish 性能)
- 合计 1 周左右,可以串行也可以 A.2 + A.3 并行(都是 emulator 上验,只有 A.1 需要物理 8BitDo)

**Phase 0 任务里要预留接口给所有 fallback** — 不要把 sshj / WebGL renderer / Base64 等硬编码,设计成可切换。Stage A 验过后大概率不用切,但留接口的成本几乎为 0,truncate 设计的成本很高。
