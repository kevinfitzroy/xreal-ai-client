# XREAL AI Client — HarmonyOS 端(第三客户端)

> **状态:脚手架 + 代码骨架已就绪,未编译、未上真机。** 立项 2026-06-01。
> 本端照着 **Android 实现 + [`SPEC.md`](../SPEC.md) 契约**写,与 iOS 平级,是 SPEC §11 平台矩阵的第三列。
> **没有编译环境**(无 DevEco Studio),所以这一轮只尽量备好代码 + 文档;凡涉及编译/签名/真机/二选一决策的,
> 都**搁置并文档化**(见下)。下一步(有环境后)再编译验证。

---

## 这是什么

跟 Android/iOS 同一个产品:**Agent Deck** —— host→project 列表 + 真 SSH 终端 + 物理键/语音,跑在 AR 眼镜上。
HarmonyOS 端用 **ArkTS/ArkUI**,核心仍是 **Web 组件(ArkWeb)跑共享 `index.html`(xterm.js)** 当终端 UI,
ArkTS 直连 SSH,同 app 内语音 → 豆包 ASR → 直写 SSH。架构与 Android/iOS 同构,只换平台落点。

## 目录

```
harmony/
├── README.md                    ← 本文件(入口)
├── sync-web-assets.sh           ← 把共享 Web 资产(android assets)同步进 rawfile
├── docs/
│   ├── adaptation.md            ← 主适配设计:逐能力对照 Android + SPEC §11,落点 + 引用
│   ├── DECISIONS.md             ← ⭐ 需你明天亲自拍板的分叉(每条都已把两条路调研+实现/文档化)
│   ├── HUMAN-TASKS.md           ← ⭐ 只有你(有环境/真机/华为账号)能做的事
│   └── ssh-options.md           ← SSH 两条路(A=libssh2/NAPI、B=纯 ArkTS)深挖 + 完成清单
└── app/                         ← DevEco Stage 模型工程骨架
    ├── AppScope/ , build-profile.json5 , hvigorfile.ts , oh-package.json5
    └── entry/src/main/
        ├── module.json5         ← 权限(INTERNET/MICROPHONE/KEEP_BACKGROUND_RUNNING)+ ability
        ├── ets/                 ← 27 个 .ets(~1900 行 ArkTS,见 adaptation.md 代码地图)
        ├── cpp/                 ← 路径 A 的 NAPI libssh2 封装骨架(CMake + napi_init.cpp + .d.ts)
        └── resources/rawfile/   ← 共享 index.html + xterm + 字体(从 android 复制)
```

## 当前能跑到哪一步(诚实评估)

| 层 | 状态 |
|---|---|
| 工程骨架(配置/权限/资源/入口) | ✅ 按规范写好,DevEco 应能识别;⚠️ `oh_modules`/lock/`hvigor-config.json5` 需首次 `ohpm install`/DevEco 补 |
| 终端 Web 层 + ArkTS↔JS 桥 | ✅ 代码完整(`Index.ets`/`TerminalBridge.ets`/`TermJs.ets`/`WebAssets.ets`),严格对齐 index.html 契约 |
| 列表/manifest/状态合并 | ✅ 代码完整(`ManifestFetcher`/`Models`/`SettingsStore`),逻辑照 SPEC §2/§3/§8 |
| 语音(录音/ASR/gzip/帧/状态机) | ✅ 代码完整(`voice/*`),照 Android 逻辑 + 调研的鸿蒙 API |
| 物理键 + 外接键盘检测 | ✅ 代码完整(`KeyRouter`),⚠️ 8BitDo 实际 KeyCode 需真机验 |
| **SSH 传输** | ⚠️ **两条 backend 都起了骨架,均未完成**:路径 A 需交叉编译 libssh2.so;路径 B 协议栈手搓未完。**选哪条 = 你拍板(DECISIONS D1)** |
| 编译 / 签名 / 真机 | ❌ 无环境,全部搁置(HUMAN-TASKS) |

## 你明天上线先看这两个

1. **[`docs/DECISIONS.md`](docs/DECISIONS.md)** —— 需你拍板的分叉(SSH 走 A 还是 B 是头号);每条我都把两条路调研/实现/文档化了,你只做选择。
2. **[`docs/HUMAN-TASKS.md`](docs/HUMAN-TASKS.md)** —— 装 DevEco、华为实名账号签名、交叉编译 libssh2、真机验 8BitDo/麦克风/眼镜——这些我做不了。

读完这两个,再看 [`docs/adaptation.md`](docs/adaptation.md) 了解整体设计与代码地图。
