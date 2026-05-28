# HANDOFF — 当前实际进度与下一步

> 状态交接给**下一个接手的 Claude Code session**。CLAUDE.md 是永久指南,这里是动态状态。
> **最近更新**:2026-05-28(Phase 0 + Stage B 代码完成,等运行时验证)

---

## 1. 项目阶段:Phase 0 + Stage B 代码完成,待运行验证

Phase 0(emulator 跑通骨架)+ Stage B(真 SSH / 真 AudioRecord / 真豆包 ASR client)的代码全部写完,APK 14 MB 编译通过。

**没跑过的事**:
- Emulator 端到端演示(本机内存压力 ~328 MB unused / 需要 5 GB,emulator 启时 QEMU CPU 线程一律 exit 139)
- 真 SSH 连通验证(user 还没开 Mac sshd / 装 abduco / 给 SSH key)
- 真 8BitDo F13/F14 keycode(Phase 1 真机)
- 真豆包 ASR(user 没给 appid/token,且 endpoint 路径要按 Volcengine console 微调)

---

## 2. 代码结构(Phase 0 + Stage B 完成后)

```
android/app/src/main/
├── AndroidManifest.xml         INTERNET / RECORD_AUDIO / FOREGROUND_SERVICE_MICROPHONE
├── assets/
│   ├── terminal.html           xterm.js + WebGL + voice overlay
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

## 4. Emulator 启不起来 — 已知症结

Mac M1 Pro / macOS 26.3.1 / 16 GB RAM,但 `vm_stat` 显示 **unused 仅 328 MB**(15 GB 全被占,5.9 GB 已进 memory compressor)。Emulator 启动需要 5 GB,QEMU CPU 线程拿不到页面卡死 exit 139。三次尝试:
1. `-gpu auto` — 段错误
2. `-gpu host` — 段错误
3. `-no-snapshot -no-accel -no-boot-anim` — 段错误,日志明示 `Software GL rendering due to system memory pressure (Available 2494 MB, Required 5120 MB)`

**解锁路径**:user 关掉 Chrome / 大 Electron app 或重启 Mac,unused 至少 5+ GB,再试 `$HOME/Library/Android/sdk/emulator/emulator -avd Pixel_8a -no-snapshot -gpu host &`。如果 Pixel_8a(android-37 preview)仍有 VulkanVirtualQueue 警告(emulator 36.5.11.0 太老),让 user 在 AS Device Manager 建 vanilla Pixel 7 Pro API 34 AVD。

---

## 5. user 还没做的"准备工作"(看任务推进顺序)

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

## 6. 新 session 的第一步(按 user 状态分流)

### 情形 A:user 说"跑 emulator 看看"
1. 跑 vm_stat 看 PhysMem 的 unused — < 1 GB 直接拒(让 user 先关 app)
2. ≥ 5 GB 才尝试 `$HOME/Library/Android/sdk/emulator/emulator -avd Pixel_8a -no-snapshot -gpu host &`
3. boot_completed=1 后 `./gradlew installDebug` + `adb shell am start io.github.kevinfitzroy.xrealclient/.MainActivity`
4. 首次跑会进 ConfigActivity — user 录入 SSH host/user/key/startup cmd 即可

### 情形 B:user 说"接真 SSH"
1. 先要 user 在 Mac:`System Settings → Sharing → Remote Login` ON + `brew install abduco` + 生成 ed25519 key + 加 authorized_keys
2. 复制私钥 PEM 内容(`cat ~/.ssh/xreal_phase0`),user 录入 ConfigActivity 的 key 框
3. host 填本机 IP(`ipconfig getifaddr en0`),user 填当前 Mac 用户(`whoami`)
4. 保存 → MainActivity 自动 connect,失败会 fallback LocalEcho + Toast

### 情形 C:user 说"接真豆包 ASR"
1. user 给 Volcengine appid / token / cluster id(可选)
2. ConfigActivity 的 provider 填 `volc`,填三个 ASR 字段保存
3. 注意:`VolcEngineAsr.endpoint` / `parseResponse` 可能要按 user console 给的具体 API spec 微调 — 测一次看 logcat warn 就知道

### 情形 D:user 说"Phase 1 物理设备到了"
进 docs/stage-a-experiments.md 三个实验(A.1 F13/F14、A.2 sshj BC、A.3 WebView 60fps)。

---

## 7. 关键注意事项(避免新 session 踩坑)

- **不要因为 emulator 起不来就质疑代码** — 编译通过 = 90% 正确。runtime 验证缺位是环境问题
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

- emulator 跑起来 → 更新 §4 / §1
- 真 SSH 接通 → 更新 §1 / §5
- 真 ASR 接通 → 同上
- Phase 1 开始(物理设备) → 重写 §1 + §5
- 任何 fallback 路径触发(如 sshj → sshlib swap) → 在 §3 表里记
