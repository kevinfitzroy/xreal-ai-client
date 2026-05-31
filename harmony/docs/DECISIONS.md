# HarmonyOS 适配 — 需你拍板的分叉

> 每条都按你的要求「**两条路都调研 + 尽量都实现/文档化**」,你只做选择。决定后我接着把选中那条做完。
> 优先级:**D1(SSH backend)是头号**,它决定整端能不能连;其余可先用默认值往前推。

---

## D1 ⭐ SSH backend:libssh2/NAPI(A) vs 纯 ArkTS(B)

**这是整个 HarmonyOS 端最大的技术分叉**(深挖见 [`ssh-options.md`](ssh-options.md))。两条都已起骨架,接同一组 `PtyChannel` 接口,切换只改 `ssh/SshBackend.ets` 的 `BACKEND` 常量。

| | **A — libssh2 + NAPI** | **B — 纯 ArkTS over TCPSocket** |
|---|---|---|
| 类比 | Android **sshj**(成熟库 + 薄封装) | iOS **Citadel**(纯语言层实现) |
| ProxyJump(多跳) | 原生 `libssh2_channel_direct_tcpip`(现成) | 要自己实现 direct-tcpip channel |
| 工作量 | 写 NAPI 桥(已起骨架)+ **交叉编译 libssh2.so** | 手搓 SSH 协议栈(KEX/认证/channel,数千行) |
| 依赖 | native .so(需编译环境 + Lycium 交叉编译) | 零 native;全用 `@kit.CryptoArchitectureKit` |
| 风险 | 无公开「libssh2+鸿蒙 NAPI」样例,你是早期实践者 | chacha20 要 API22+(用 AES-GCM 替);协议正确性敏感 |
| 可审计 | 中(C 库) | 高(100% ArkTS) |
| 代码现状 | `ssh/backend/NativeSshChannel.ets` + `cpp/`(完整封装骨架,.so 待编译) | `ssh/backend/ArkSshSession.ets` + `arkts/`(版本交换+KEXINIT 已实,KEX 派生/GCM/认证待补) |

- **我的建议:A**。贴合你 Android 的「成熟库」哲学,ProxyJump 有原生 channel,协议正确性靠 libssh2 保证;唯一代价是交叉编译一次 libssh2(HUMAN-TASKS T3)。
- **选 B 的理由**:不想引 native、想 100% ArkTS 可审计、且能接受手搓协议的工期。
- **第三条(降级/PoC)**:Flutter-ohos + dartssh2(纯 Dart,已在鸿蒙跑通)——但会改 App 框架(ArkUI→Flutter),仅作快速验证/降级备选,不建议主线。

**默认**:代码里 `BACKEND='arkts'`(纯 ArkTS 不依赖 native 工具链,工程能直接打开/编译;协议未完成 → 连接抛 NotImplemented)。**你选 A 的话改成 `'native'` + 走 T3 编译 .so。**

---

## D2 SSH-over-443 隧道(翻墙):HarmonyOS 用什么代理内核

SPEC §5.1:海外 host 从国内连,:22 被 GFW 卡 → 走 :443 vmess 隧道。Android 内嵌 xray-core(gomobile aar),iOS 规划 sing-box。HarmonyOS 同样要一个**本地端口转发内核**(dokodemo-door 等价)。

| 路 | 说明 |
|---|---|
| **sing-box(gomobile)** | 有官方 gomobile 库,`direct` inbound + `override_address/port` = dokodemo 等价。与 iOS 同选型,可复用调研 |
| **xray-core(gomobile)** | 与 Android 同核;鸿蒙能不能 gomobile bind 出 .so/.har 给 ArkTS 调需验(go→ohos 工具链) |
| **纯 ArkTS vmess** | 不现实(要手搓 vmess+TLS),不考虑 |

- **建议:sing-box(gomobile)**,与 iOS 对齐;但**这条依赖 D1 先定**(隧道是 SSH 连接的下层,backend 定了才好接注入点)。
- **现状**:`SshConnection.ets` 已留 proxy 透传位,**隧道内核未接**(第一版可先只支持直连 host / 国内 host,海外 host 待隧道)。
- **默认**:先不接隧道(直连),隧道作为 D1 之后的下一步。**这条明天可不急,先 D1。**

---

## D3 Web 资产加载:file://+universalAccess(已实现)vs resource://$rawfile

终端 UI 是共享 `index.html` + 同目录字体/addon。ArkWeb 在 API 12 下 resource:// 协议默认禁跨源 → 字体/fetch 易失败。

| 路 | 说明 | 现状 |
|---|---|---|
| **file:// + setPathAllowingUniversalAccess**(整目录放行)| = Android `allowFileAccessFromFileURLs`,字体/addon 一次放行。需先把 rawfile 拷进沙箱 | ✅ **已实现**(`WebAssets.ets` + `Index.ets`) |
| **resource:// + `$rawfile('index.html')`** | 最简单,src 直接给 rawfile;但同源限制可能挡字体 | 备选(改 `Index.ets` 一行 src) |

- **已默认走 file://**(最贴近 Android 的成熟做法)。**这条无需你拍板**,除非真机上 file:// 出问题 → 回退 resource://(已文档化)。列在这里只为知情。

---

## D4 桥数据通道:Base64-over-string(已实现)vs runJavaScriptExt ArrayBuffer

终端字节双向传输。Android/iOS 都走 Base64-over-string;HarmonyOS 多一个选项:`runJavaScriptExt` + proxy ArrayBuffer 参数可直传二进制(免 b64 开销)。

- **已默认 Base64**(三端一致,降低跨端心智负担;`Bytes.ets`/`TermJs.ets`)。性能不够再切 ArrayBuffer(`TermJs` 改 `runJavaScriptExt`)。**无需拍板**,知情即可。

---

## 决定记录(你填)

| # | 决定 | 日期 |
|---|---|---|
| D1 | ☐ A(libssh2/NAPI) ☐ B(纯 ArkTS) | |
| D2 | ☐ sing-box ☐ xray ☐ 先不接(直连) | |
