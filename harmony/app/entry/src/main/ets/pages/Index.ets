import { webview } from '@kit.ArkWeb';
import { AppController } from '../AppController';
import { TerminalBridge } from '../bridge/TerminalBridge';
import { KeyRouter, KeyActions } from '../input/KeyRouter';
import { WebAssets } from '../terminal/WebAssets';
import { Log } from '../util/Logger';

/**
 * ArkUI 壳 —— 对齐 Android `MainActivity` 的 UI 部分(装 WebView + 抢键 + 生命周期)。
 * 业务逻辑全在 AppController(= MainActivity 的逻辑部分)。
 *
 * 终端 UI = 共享 index.html(SPEC §11),经 file:// + setPathAllowingUniversalAccess 加载(同源放行字体/addon)。
 * 桥 = javaScriptProxy 注册 TerminalBridge 为 window.Bridge。软键盘 = onInterceptKeyboardAttach 抑制。
 * 物理键 = 根容器 onKeyEvent → KeyRouter(须 focusable+defaultFocus 抢焦,HarmonyOS 是组件焦点级事件)。
 */
const TAG = 'Index';

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private app: AppController = new AppController(this.controller);
  private bridge: TerminalBridge = new TerminalBridge(this.app);
  private keyRouter: KeyRouter = new KeyRouter({
    voiceDown: () => this.app.voiceDown('zh'),
    voiceUp: () => this.app.voiceUp('zh'),
    back: () => this.app.back(),
    pageUp: () => this.app.pageUp(),
    pageDown: () => this.app.pageDown()
  } as KeyActions);
  private webDir: string = '';

  aboutToAppear(): void {
    this.webDir = WebAssets.prepare();
    this.keyRouter.watchKeyboard((present: boolean) => this.app.onKeyboardChange(present));
  }

  onPageShow(): void { this.app.onForeground(); }   // 回前台重拉列表(对齐 Android onStart / iOS willEnterForeground)

  build() {
    Stack() {
      Web({ src: this.webDir ? `file://${this.webDir}/index.html` : 'about:blank', controller: this.controller })
        .javaScriptAccess(true)
        .fileAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .imageAccess(true)
        // JS→ArkTS 桥:window.Bridge.<method>。methodList 含同步 hasHardwareKeyboard。
        .javaScriptProxy({
          object: this.bridge,
          name: TerminalBridge.JS_NAME,
          methodList: TerminalBridge.METHOD_LIST,
          controller: this.controller
        })
        .onControllerAttached(() => {
          try {
            // 整目录放行 file:// 跨源(= Android allowFileAccessFromFileURLs):字体/addon 同源加载
            this.controller.setPathAllowingUniversalAccess([this.webDir]);
          } catch (e) { Log.w(TAG, 'setPathAllowingUniversalAccess ' + e); }
        })
        // 网页 input 获焦不弹系统软键盘(= Android FLAG_ALT_FOCUSABLE_IM)。硬件键盘 + 自绘虚拟键盘已够。
        .onInterceptKeyboardAttach(() => { return { useSystemKeyboard: false }; })
        .onPageEnd(() => { this.app.onReady(); })   // 页面就绪:导入配置 + 拉列表
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0d0f16')
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((e: KeyEvent) => {
      // F1/F2/Shift+方向 → KeyRouter 消费;其余(列表导航/终端输入)透传给 Web/xterm。
      const consumed = this.keyRouter.handle(e.keyCode, e.type as number, e.metaKey);
      if (consumed) { e.stopPropagation(); }
    })
  }
}
