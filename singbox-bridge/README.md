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
前置:**Go 1.25.x**(sing-box v1.13 本身只要 go1.24.7,但 gomobile 的 `golang.org/x/mobile` 要 go1.25.0 → 实测下限被抬到 1.25;本机有 go1.25.x 缓存即可,**无需手动升 go**)、gomobile/gobind、能翻墙拉 sing-box。

`build-ios.sh` 已内置三处构建硬化(都踩过):① 自动用缓存的 **go1.25.x toolchain 当 GOROOT + GOTOOLCHAIN=local**(否则 gomobile 子进程会去下非法的 "go1.25");② `golang.org/x/mobile` 经 `tool` 指令进 go.mod(gomobile bind 必需);③ `GOSUMDB=off`(gomobile 内部 tidy 走 goproxy.cn 的 sumdb 常 504)。

`go.mod`/`go.sum` 已提交(可复现);首次在新机 build 若缺 `go.sum` 会自动 `go mod tidy` 重生成。

**build tag**:`with_utls`(reality uTLS 指纹必需);tun/quic/wireguard/clash-api 未启用以缩体积。

没 build → `SingboxBridge.load()` 返回 nil,带 proxy 的 host 连接失败但**直连 host 照常**。
