import { webview } from '@kit.ArkWeb';
import { Bytes } from '../util/Bytes';
import { Log } from '../util/Logger';

/**
 * ArkTS→JS 封装 —— 对齐 Android `MainActivity` 里那批 `webView.evaluateJavascript("window.xxx(...)")`。
 * 调 index.html 暴露的 window 函数。所有调用须在 UI 线程(controller.runJavaScript 要求)。
 */
const TAG = 'TermJs';

function q(s: string): string { return JSON.stringify(s); }   // 安全字符串字面量(等价 Android 的 JSONObject.quote)

export class TermJs {
  constructor(private controller: webview.WebviewController) {}

  private run(js: string): void {
    try { this.controller.runJavaScript(js); } catch (e) { Log.w(TAG, 'runJS ' + e); }
  }

  /** 整批替换 host 列表(JSON 字符串,RenderHost[])。 */
  setHosts(json: string): void { this.run(`window.setHosts(${q(json)})`); }

  /** 远端 PTY 字节 → 终端(b64)。对齐 Android writeToTerm。 */
  writeToTerm(data: Uint8Array): void { this.run(`window.writeToTerm('${Bytes.toB64(data)}')`); }

  showTerminal(name: string, type: string): void { this.run(`window.showTerminal(${q(name)},${q(type)})`); }
  showList(): void { this.run('window.showList()'); }
  syncSize(): void { this.run('window.syncSize && window.syncSize()'); }

  showOverlay(status: string, text: string): void { this.run(`window.showOverlay(${q(status)},${q(text)})`); }
  hideOverlay(): void { this.run('window.hideOverlay()'); }

  /** 外接键盘插拔 → 显隐虚拟键盘。 */
  setHwKeyboard(present: boolean): void { this.run(`window.setHwKeyboard && window.setHwKeyboard(${present})`); }
}
