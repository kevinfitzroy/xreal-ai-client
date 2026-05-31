# HarmonyOS 适配设计

> 照 **Android 实现 + [`SPEC.md`](../../SPEC.md) 契约** 落 HarmonyOS(ArkTS/ArkUI)。本文是主设计 + 代码地图。
> 跨端行为(列表/状态/语音/按键/配置形状)的真相在 SPEC,**不在这里重述**;这里只记 HarmonyOS 平台落点。
> 决策分叉见 [`DECISIONS.md`](DECISIONS.md),需人工的见 [`HUMAN-TASKS.md`](HUMAN-TASKS.md)。

---

## 1. 架构(与 Android/iOS 同构)

```
┌─ HarmonyOS 上一个 HAP ───────────────────────────────────┐
│  ArkWeb Web 组件(共享 index.html:xterm.js+WebGL)← UI 层 │
│      ↑ runJavaScript(window.*)  ↓ javaScriptProxy(Bridge.*)│
│  TerminalBridge(JS↔ArkTS 桥,name="Bridge")              │
│      ↑                          ↓                          │
│  SSH(backend:libssh2/NAPI 或 纯 ArkTS)— TCP→SSH→PTY     │
│      ↑                                                     │
│  VoiceController(状态机)                                  │
│  ├─ onKeyEvent 路由 F1/F2(物理键,KeyRouter)             │
│  ├─ AudioCapturer 16k PCM → gzip → 豆包 WS(VolcAsr)      │
│  └─ injectText → PtyChannel.write(后台单线程)           │
└────────────────┬──────────────────────────────────────────┘
                 │ Raw SSH(:22),内网经 via 跳板,海外可经 :443 隧道(D2 待定)
                 ▼  多台 host:tmux + Claude Code + Maestro
```

与 Android 唯一的**结构性差异**:见 §3 的两个「⚠️ 行为差异」(桥跑主线程、键事件组件焦点级)。

## 2. 能力映射(Android → HarmonyOS,SPEC §11 第三列)

| 契约项 | Android | HarmonyOS(本端落点) | 文件 |
|---|---|---|---|
| 终端 UI | WebView + xterm.js | **ArkWeb `Web` + 同一 index.html** | `pages/Index.ets` |
| ArkTS→JS | `evaluateJavascript` | `controller.runJavaScript("window.*")` | `terminal/TermJs.ets` |
| JS→ArkTS 桥 | `@JavascriptInterface` | **`javaScriptProxy`**(name="Bridge",methodList) | `bridge/TerminalBridge.ets` |
| 本地资产/字体 | `allowFileAccessFromFileURLs` | **`file://` + `setPathAllowingUniversalAccess`**(拷沙箱)| `terminal/WebAssets.ets` |
| 软键盘抑制 | `FLAG_ALT_FOCUSABLE_IM` | **`onInterceptKeyboardAttach`→`useSystemKeyboard:false`** | `pages/Index.ets` |
| 全屏沉浸 | 全屏 flags | `setWindowLayoutFullScreen` + `setWindowSystemBarEnable([])` | `entryability/EntryAbility.ets` |
| SSH | sshj | **libssh2/NAPI 或 纯 ArkTS**(D1)| `ssh/*` |
| 多跳 ProxyJump | sshj LocalPortForwarder | libssh2 `direct_tcpip` / ArkTS direct-tcpip(D1)| `ssh/SshConnection.ets` |
| SSH-over-443 | 内嵌 xray(aar)| sing-box/xray gomobile(D2,待接)| `ssh/SshConnection.ets`(proxy 透传位)|
| 物理键路由 | `dispatchKeyEvent` | **组件 `onKeyEvent`**(focusable+defaultFocus 抢焦)| `input/KeyRouter.ets` |
| 外接键盘检测 | `Configuration.keyboard` | `inputDevice.on('change')` + `getKeyboardType` | `input/KeyRouter.ets` |
| 麦克风 | `AudioRecord` 16k PCM | `AudioCapturer` 16k/mono/S16LE `on('readData')` | `voice/AudioCapturer.ets` |
| ASR WS | OkHttp 豆包流式 | `@ohos.net.webSocket`(header 鉴权 + ArrayBuffer)| `voice/VolcAsr.ets` |
| gzip | — | **`deflateInit2 windowBits=31`**(非 `compress()`,后者是 zlib 非 gzip)| `voice/Gzip.ets` |
| 语音保活 | 前台 Service | **长时任务** `backgroundTaskManager`(AUDIO_RECORDING)| `voice/VoiceController.ets` |
| 配置注入(Valet)| `adb push`→私有存储 | **`hdc file send`**→`/data/local/tmp/xreal_import`→导入 | `config/SettingsStore.ets` |
| manifest/状态 | ManifestFetcher | 同逻辑,SSH exec cat | `manifest/ManifestFetcher.ets` |
| 持久日志/截屏 | AppLog / `adb` | `hilog`(`hdc hilog`)/ `hdc shell snapshot_display` | `util/Logger.ets` |

## 3. 两个必须知道的行为差异(从 Android 移植最容易栽)

1. **桥方法跑 ArkTS 主线程**(Android 是非 UI binder 线程)。`onInput → SSH 写`**绝不能在桥里阻塞** →
   `PtyChannel.write` 内部派 `taskpool` 后台单线程(`backend/NativeSshChannel.ets`)。这与 memory `input-path-constraints`
   「SSH 写入必须后台单线程」同源,只是 HarmonyOS 主线程更敏感,务必显式派发。
2. **键事件是组件焦点级**(Android 是 Activity 全局 `dispatchKeyEvent`)。根容器须 `focusable(true).defaultFocus(true)`
   抢焦,否则 F1/F2 到不了 app(`pages/Index.ets`)。真正的全局 hook(`inputMonitor`)是 system API,三方拿不到。

## 4. 代码地图(27 个 .ets)

```
ets/
├── pages/Index.ets            ArkUI 壳:Web + onKeyEvent + 生命周期 → AppController
├── AppController.ets          编排核心(= MainActivity 逻辑):实现 BridgeHandlers + VoiceHost
├── entryability/EntryAbility.ets  进程入口:全屏沉浸 + 麦克风权限 + AppCtx
├── bridge/TerminalBridge.ets  JS→ArkTS 桥对象(window.Bridge,methodList)
├── terminal/
│   ├── TermJs.ets             ArkTS→JS(window.setHosts/writeToTerm/showTerminal/...)
│   └── WebAssets.ets          rawfile→沙箱拷贝(file:// 同源加载字体/addon)
├── ssh/
│   ├── PtyChannel.ets         接口:PtyChannel / SshSession / SshBackend
│   ├── SshBackend.ets         ⭐ BACKEND 常量(native/arkts,D1)+ 工厂
│   ├── SshConnection.ets      门面:via 跳板链 + proxy 透传 + tmuxAttachCommand
│   ├── backend/
│   │   ├── NativeSshChannel.ets   路径 A:libssh2 NAPI 的 ArkTS wrapper
│   │   └── ArkSshSession.ets      路径 B:纯 ArkTS SSH(版本交换+KEXINIT 已实,余骨架)
│   └── arkts/
│       ├── SshWire.ets        ✅ SSH 线格式编解码(完整,可单测)
│       ├── SshCrypto.ets      ✅ cryptoFramework 原语(ed25519/x25519/aes-gcm/hmac;4 编码 TODO)
│       └── Transport.ets      ✅ TCPSocket + SSH 包帧(明文帧完整,GCM 钩子待接)
├── manifest/ManifestFetcher.ets   cat projects.json/status.json → 合并 → RenderHost[]
├── config/SettingsStore.ets   Valet 导入 + hosts/proxies/asr 读取
├── model/Models.ets           HostConfig/ProjectInfo/ProxyConfig/AgentState/RenderHost
├── voice/
│   ├── VoiceController.ets     hold-to-talk 状态机 + 长时任务 + 🎤 前缀注入
│   ├── AudioCapturer.ets       16k/mono PCM,200ms 攒包
│   ├── VolcAsr.ets             豆包流式 WS(鉴权 header + 二进制帧)
│   ├── VolcFrame.ets           豆包 v3 二进制协议帧(含 WithEvent 事件帧边界保护)
│   ├── Gzip.ets                内存 gzip/gunzip(windowBits=31)
│   └── Hotwords.ets            BASE 通用词 + project 热词合并
├── input/KeyRouter.ets         F1/F2/翻页路由 + 外接键盘检测
└── util/
    ├── AppCtx.ets              全局 ability context
    ├── Bytes.ets               Base64/UTF-8
    └── Logger.ets              hilog 封装
```

## 5. 与 SPEC 的一致性

- **列表/状态**(SPEC §2/§3):`ManifestFetcher` 照 manifest schema + 4 态合并规则(host 不可达→disconnected,有上报→用,无→unknown);render JSON 形状 = ROADMAP §4 契约(`[{name,addr,up,proxy,projects:[{name,session,type,state,since,preview}]}]`,preview 恒 null)。
- **语音**(SPEC §4):AI-agent 类加 `🎤 ` 前缀,ssh 类不加;直写 SSH outputStream(`VoiceController.injectText`→`PtyChannel.write`)。
- **SSH/会话**(SPEC §5):tmux `new -A`、`-u` UTF-8、conf 注入(history-limit + 半页翻页);ed25519;TOFU。
- **输入语义**(SPEC §6):F1=语音 hold-to-talk(KeyType Down/Up)、F2=返回、Shift+↑/↓=翻页(→ tmux S-Up 绑定 `\x1b[1;2A`)。
- **配置/Valet**(SPEC §8):无设置 UI;hdc file send→staging→导入;真实 IP 只进 host;私钥纯文件名防遍历。
- **优雅降级**(SPEC §9):SSH 失败提示不崩;语音无凭证降级;backend 不可用不影响 UI 壳。

> 这一端**不引入任何新跨端契约** —— 全部复用 SPEC v1。若 HarmonyOS 暴露出需改契约的点,先改 SPEC 再三端对齐(SPEC §12),不在本端私自发明。
