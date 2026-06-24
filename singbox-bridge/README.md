# singbox-bridge

官方 **sing-box** 的极薄 gomobile 封装 —— iOS SSH-over-443 隧道引擎(替代 `xray-bridge`)。

## 为什么存在
真机反馈:vless + Reality(`xtls-rprx-vision`)经 **xray-core**(gomobile)隧道**连上即停**;同节点同协议用桌面 **sing-box**(v2rayN core)很稳。→ 复刻桌面那套已验证可用的实现,iOS 隧道引擎换 sing-box。详见仓库 issue #46。

- **iOS 先行**:本模块只产 iOS framework。Android 的 SSH-over-443 仍走 `xray-bridge`(当前只 vmess,非问题所在),后续再迁。
- **单引擎(决策 B)**:sing-box 同时接管 **vmess + vless**(它都支持),iOS 侧不再用 xray。

## 设计
- Go 侧零业务逻辑:share link 解析 + sing-box JSON 生成全在 Swift(`SshConnect.swift` 的 `SingboxConfig`),这里只 `box.New` 起实例。
- 无 TUN / 无 VpnService:只跑本地 `direct` inbound(route-action override → 服务端 `127.0.0.1:22`),app 把 SSH socket 接到本地端口。
- 按 key 多实例。导出 `Start/Stop/Running/Version`(gomobile → C 符号 `Singboxbridge*`,Swift dlsym 调用)。

## build
```bash
cd singbox-bridge && ./build-ios.sh     # → ios/App/Frameworks/Singboxbridge.framework(不进 git)
```
前置:Go ≥ 1.24(sing-box v1.13 要 go1.24.7;本机 go1.25 满足,**无需升 go**)、gomobile/gobind、能翻墙拉 sing-box。

**首次 build** 会 `go mod tidy` 解析 sing-box 全量依赖并生成 `go.sum`(Claude 环境无网络,仓库只 pin 直接依赖)——build 通过后请把 `go.mod`/`go.sum` 提交。

**build tag**:`with_utls`(reality uTLS 指纹必需);tun/quic/wireguard/clash-api 未启用以缩体积。

没 build → `SingboxBridge.load()` 返回 nil,带 proxy 的 host 连接失败但**直连 host 照常**。
