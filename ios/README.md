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
xcodebuild -project XrealPOC.xcodeproj -scheme "Agent Station" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ./DerivedData build
xcrun simctl boot "iPhone 17"   # 若未启动
APP="DerivedData/Build/Products/Debug-iphonesimulator/Agent Station.app"
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

## 注意
- 不 commit(用户没让)。`*.xcodeproj`、`DerivedData/`、throwaway key 已进 `.gitignore`。
- 真机另说:需代码签名(`devicectl install` 要签名 .app),POC 不覆盖。
