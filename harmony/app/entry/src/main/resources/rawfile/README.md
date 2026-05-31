# rawfile/ — 共享 Web UI 资产(= Android `assets/` 等价物)

ArkWeb 的 `Web` 组件从这里加载终端 UI。内容是**从 `android/app/src/main/assets/` 复制的共享资产**,
与 iOS 的 `ios/App/web/` 同源——三端共用同一套 `index.html`(SPEC §11:UI 是平台中立契约)。

| 文件 | 来源 | 说明 |
|---|---|---|
| `index.html` | android assets(零改动) | Agent Deck 列表 ⇄ 终端 SPA;桥用 `window.Bridge.*`(见下) |
| `xterm.js` / `xterm.css` | 同 | xterm.js 5.x |
| `addon-{fit,webgl,search,unicode11}.js` | 同 | xterm addons |
| `meslo-powerline.otf` / `sarasa-term.ttf` | 同 | Latin/powerline + CJK 字体 |

## 桥契约(ArkTS 侧 `bridge/TerminalBridge.ets` 必须满足)

`index.html` 通过 `window.Bridge.<method>` 调原生(JS→ArkTS),通过 `window.<fn>` 接收原生推送(ArkTS→JS):

- **JS→ArkTS**(`window.Bridge`,ArkTS 用 `javaScriptProxy` 注册,name=`"Bridge"`):
  `openProject(host,session,name,type)`、`onInput(b64)`、`onResize(cols,rows)`、
  `voiceDown(lang)`、`voiceUp(lang)`、`vkeyEnter()`、`vkeyEsc()`、`goHome()`、`hasHardwareKeyboard():boolean`(同步)
- **ArkTS→JS**(`controller.runJavaScript("window.<fn>(...)")`):
  `setHosts(json)`、`showTerminal(name,type)`、`showList()`、`writeToTerm(b64)`、`syncSize()`、
  `showOverlay(s,t)`、`hideOverlay()`、`setHwKeyboard(present)`、`updateProject(host,name,patch)`

## 同步策略

`index.html` 等共享资产**改动只在 `android/app/src/main/assets/` 改一次**(它是 SPEC 意义上的契约源),
再复制到这里和 iOS。重新同步:
```
cp ../../../../../../../android/app/src/main/assets/{index.html,xterm.js,xterm.css,addon-*.js,*.otf,*.ttf} .
```
(路径相对本目录;或在仓库根跑 `harmony/sync-web-assets.sh`,见该脚本。)
