# iOS POC — terminal stack tracer bullet

Stage-A risk验证:把 Android 的终端 UI 栈(xterm.js + Base64 桥 + 字体)移植到 iOS。
**模拟器、零签名**。`SPEC.md` 是平台中立契约,这里只验平台实现。

## 它做了什么
- UIKit app(无 storyboard,programmatic `UIWindow`),全屏 `WKWebView`。
- WKWebView 复用 **Android 那份原样的 `web/index.html` + xterm 资产**(从 `android/app/src/main/assets/` 复制)。
- 注入 `WKUserScript`(`.atDocumentStart`)定义 `window.Bridge` shim,把
  `Bridge.onInput/onResize/openProject/...` 转成 `window.webkit.messageHandlers.bridge.postMessage`。
- 第二个 user script 把 JS `console.*` + `window.onerror` 转发到 native(POC 的主要仪器)。
- **M1**:启动→`showTerminal('iOS POC','ssh')`→等 `term` 就绪→写 banner→
  `Bridge.onInput(btoa('echo via bridge: hello'))` 走 JS→native→`writeToTerm` 回写,证 echo 闭环。
- **M2**:Citadel(SwiftNIO SSH)连本地 throwaway sshd,PTY ↔ Bridge,渲染真 shell。

## 重跑
```bash
cd ios
xcodegen generate
xcodebuild -project XrealPOC.xcodeproj -scheme "Agent Deck" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ./DerivedData build
xcrun simctl boot "iPhone 17"   # 若未启动
APP="DerivedData/Build/Products/Debug-iphonesimulator/Agent Deck.app"
xcrun simctl install booted "$APP"
xcrun simctl launch --console booted io.github.kevinfitzroy.xrealclient
xcrun simctl io booted screenshot /tmp/xreal-ios-poc.png
```

## M2 配置注入(模拟器开发期通道 = adb push 的 iOS 等价物)
app 启动时从自身 Documents 读 throwaway key/user/port(没有就退回 M1 echo):
```bash
DC=$(xcrun simctl get_app_container booted io.github.kevinfitzroy.xrealclient data)
cp poc_key "$DC/Documents/poc_key"     # OpenSSH 格式私钥(非 PEM)
printf 'youruser' > "$DC/Documents/poc_user"
printf '2222'     > "$DC/Documents/poc_port"   # 缺省 22
```
throwaway sshd(碰不到用户真实 ~/.ssh):见 commit 说明 / 任务报告里的 sshd_config
(高端口 + 自带 authorized_keys + `PubkeyAcceptedAlgorithms +ssh-rsa`,因为 Citadel 0.12 RSA 走 legacy ssh-rsa)。

## 拨轮(可选功能,#24)

终端右缘**无极拨轮**(连续滚 + 触顶接力 tmux 深历史 + 底部"新消息"药丸)是 **编译期可选** 功能,**默认关**。

- **开关**:`ios/App/Sources/BuildFeatures.swift` 的 `static let scrollRail`。
  - `false`(默认)= **点击半屏翻页**(点上半屏=上、中段=下,发 `Shift+↑/↓` 给 tmux copy-mode)。一次一格、一次 SSH 往返,**弱网更稳**。
  - `true` = 右缘隐形拨轮(手指搭上显形、连续滚、惯性、逐行触觉)。本地缓冲丝滑滚,触顶按行发 SSH 接力 tmux —— **网络差时可能卡/抖**,故默认关。
- **改完重编即生效**(`static let` 常量,关时不进运行路径):改 `scrollRail` → `cd ios && xcodegen generate`(若新加过文件)→ `xcodebuild`。
- 手感常量(摩擦/增益/触觉疏密/接力限速)在 `TerminalScrollRail.swift` 顶部 + `TerminalViewController` 的 `handoffMinInterval`,真机给反馈后调。
- 实现只取自 PR #25 的拨轮部分(其捆绑的"语音底部控制重做"未并入,单独评审)。

## 注意
- 不 commit(用户没让)。`*.xcodeproj`、`DerivedData/`、throwaway key 已进 `.gitignore`。
- 真机另说:需代码签名(`devicectl install` 要签名 .app),POC 不覆盖。
