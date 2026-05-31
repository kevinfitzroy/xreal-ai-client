# HarmonyOS SSH 两条路 — 深挖 + 完成清单

> SSH 是 HarmonyOS 端唯一没有现成轮子的硬骨头(ohpm 上**没有**现成 SSH 库)。两条主路都已起骨架,
> 接同一组 `PtyChannel`/`SshSession` 接口(`ssh/PtyChannel.ets`),切换只改 `ssh/SshBackend.ets` 的 `BACKEND`。
> 决策见 [`DECISIONS.md`](DECISIONS.md) D1。本文给每条的**调研结论 + 现有代码 + 还差什么(完成清单)**。

需求回顾:TCP→SSH→交互式 PTY(attach tmux)+ 短命 exec channel(cat manifest/status)+ ed25519 公钥认证 + 多跳 ProxyJump。

---

## 路径 A — libssh2 + NAPI(.so)

**类比 Android sshj**:成熟 SSH 库 + 薄封装。协议正确性交给 libssh2,我们只写 NAPI 桥。

### 为什么可行
- HarmonyOS NAPI(Node-API + CMake + BiSheng/LLVM)是一等公民,成熟。
- **libssh2** 纯客户端 SSH2 库,加密后端可选 OpenSSL/mbedTLS;**OpenHarmony-SIG/tpc_c_cplusplus(Lycium)** 交叉编译框架有 OpenSSL/zlib 移植路径,官方移植实践明确推荐「仅需 SSH 协议库优先 libssh2」。
- 你要的能力 libssh2 全有:
  - `libssh2_session_handshake` / `libssh2_userauth_publickey_frommemory`(ed25519,1.9+)
  - `libssh2_channel_request_pty_ex` + `process_startup`(PTY shell,attach tmux)
  - `libssh2_channel_exec`(短命 exec,cat)
  - `libssh2_channel_direct_tcpip_ex`(**ProxyJump**,= sshj 手搓 LocalPortForwarder 的现成原语)

### 现有代码
- `cpp/CMakeLists.txt` — 链接 libssh2 + crypto + NAPI(IMPORTED 预编译库)
- `cpp/napi_init.cpp` — NAPI 模块注册 + 8 个导出函数骨架(connect/openShell/read/write/resizePty/exec/closeChannel/closeSession),每个标了对应 libssh2 调用 + 句柄表设计
- `cpp/types/libsshbridge/index.d.ts` — ArkTS 类型契约
- `ssh/backend/NativeSshChannel.ets` — ArkTS wrapper(完整:句柄管理、后台读循环、taskpool 写),native import 注释着待 .so build

### 完成清单(你 + 我)
1. **[你,T3]** Lycium 交叉编译 OpenSSL + zlib + libssh2 → `cpp/libs/arm64-v8a/*.a`,头文件 → `cpp/include/`
2. **[我]** 填 `napi_init.cpp`:
   - 句柄表(int↔`LIBSSH2_SESSION*`/`LIBSSH2_CHANNEL*` + socket fd)
   - 阻塞调用包 `napi_create_async_work`(libuv 线程池)→ 不阻塞 ArkTS 主线程
   - connect:socket connect 或经 viaHandle 的 `direct_tcpip_ex`(ProxyJump)→ handshake → host key TOFU → `userauth_publickey_frommemory`
   - read:非阻塞 `libssh2_channel_read` + EOF 处理
3. **[你+我]** 打开 `entry/build-profile.json5` externalNativeOptions + `entry/oh-package.json5` 依赖 + `NativeSshChannel` 取消 import 注释 + `SshBackend.BACKEND='native'`
4. **[你,真机]** 验 KEX/cipher 与服务端匹配(curve25519 + ed25519 + aes-gcm;libssh2 1.11 + OpenSSL 3 覆盖)

### 已知坑
- ohpm 无现成 libssh2 包,Lycium 里也未证实有现成 HPKBUILD → 大概率自写交叉编译脚本(OpenSSL/zlib 依赖已具备)。
- 无公开「libssh2+鸿蒙 NAPI SSH client」样例,你是早期实践者。
- 备选 native 库:**wolfSSH**(自带 wolfCrypt、无需 OpenSSL、体积小,塞 HAP 更友好)值得评估;**libssh**(非 libssh2)有原生 forwarding tutorial。

---

## 路径 B — 纯 ArkTS over TCPSocket + cryptoFramework

**类比 iOS Citadel**:纯语言层。零 native、100% 可审计,但要手搓 SSH 协议栈。

### 为什么可行(原料齐)
- `@ohos.net.socket` TCPSocket 收发 `ArrayBuffer`(二进制),够做 transport;`TCPSocketServer.listen` 能本地监听(ProxyJump 的本地端)。
- `@kit.CryptoArchitectureKit`(cryptoFramework)覆盖 SSH 所需原语:

| SSH 需要 | cryptoFramework | API |
|---|---|---|
| Ed25519 签名/验签 | ✅ EdDSA | 11+ |
| X25519 ECDH | ✅ `createKeyAgreement('X25519')` | 11+ |
| AES-256-GCM | ✅ `'AES256\|GCM\|NoPadding'` | 9+ |
| HMAC-SHA256/512 | ✅ `createMac` | 9+ |
| SHA1/256/512 | ✅ `createMd` | 9+ |
| **ChaCha20-Poly1305** | ⚠️ 支持但 **API 22+** | 22+ |

→ API 12 基线下用 **aes256-gcm@openssh.com**(SSH 支持,服务端 cipher 对齐即可),不用 chacha20。

### 现有代码(已实 + 骨架)
- `ssh/arkts/SshWire.ets` — ✅ **完整**:SSH 线格式(byte/uint32/string/mpint/name-list)读写 + UTF-8,纯函数可单测
- `ssh/arkts/Transport.ets` — ✅ **基本完整**:TCPSocket + SSH 二进制包帧(明文帧读写、版本串、包队列);预留 encrypt/decrypt 钩子待 GCM 接
- `ssh/arkts/SshCrypto.ets` — ✅ **原语真实**:sha256/512、hmac、x25519、ed25519 verify/sign、aes-gcm —— 全走 cryptoFramework;⚠️ 4 个「32B 原始点 ↔ Key 对象」编码转换标 TODO(cryptoFramework 对 X25519/Ed25519 的 point 编码需真机核 .d.ts)
- `ssh/backend/ArkSshSession.ets` — ⚠️ **骨架**:版本交换 + KEXINIT 构造已实;`doKex`(curve25519 派生)/`authPublicKey`/channel 层标 NotImplemented

### 完成清单(主要是我,需有环境核 cryptoFramework 编码细节)
1. **SshCrypto** 4 个 raw↔Key 转换:确认 cryptoFramework 对裸 32B X25519/Ed25519 公钥的接受编码(可能要手工包 DER SubjectPublicKeyInfo)
2. **doKex**:发 KEX_ECDH_INIT(Q_C)→ 收 REPLY(Q_S/hostkey/sig)→ 算 K + exchange hash H → ed25519 验签 + TOFU → 派生 6 把 key(RFC 4253 §7.2)→ NEWKEYS → 装 GCM 钩子到 Transport
3. **GCM 帧**:aes256-gcm@openssh.com 的 length 明文 + payload 加密 + 16B tag(填 Transport 的 encrypt/decrypt 钩子)
4. **authPublicKey**:SERVICE_REQUEST → USERAUTH_REQUEST(ssh-ed25519,签 sessionId||request)→ SUCCESS。需 OpenSSH ed25519 私钥解析(`SshKeyParser`,待写)
5. **channel 层**:CHANNEL_OPEN session → pty-req → shell/exec → CHANNEL_DATA 双向 + window adjust;exec 收到 EOF 拼 stdout
6. **多跳**:在跳板 session 上开 direct-tcpip channel 当作 ArkSshSession 的底层流
7. **随机数**:cookie/padding 用 cryptoFramework 的 `createRandom().generateRandom(n)`(代码现填 0 占位)

### 工作量
路径 B = 自研 mini-SSH 协议栈,数千行、协议正确性敏感。原料都在,**技术可行**,但比 A 多 5–10 倍工期。

---

## 第三条(降级/PoC):Flutter-ohos + dartssh2

**dartssh2**(纯 Dart,功能齐:pubkey/PTY/exec/转发)已在鸿蒙跑通,是「纯语言层 SSH 在鸿蒙可行」的实证。
但它是 **Flutter-ohos** 生态 → 改 App 框架(ArkUI→Flutter)。**不建议主线**,仅作快速验证「鸿蒙能跑通 SSH」或极端降级备选。

---

## 推荐

**主推 A(libssh2+NAPI)**:贴合 Android 架构哲学、ProxyJump 原生、协议正确性有保障,代价是交叉编译一次 libssh2。
**B 适合**:坚持零 native / 100% ArkTS 可审计、能接受工期。
两条接口一致,先按 A 推进;若交叉编译受阻,B 的骨架随时可接力。
