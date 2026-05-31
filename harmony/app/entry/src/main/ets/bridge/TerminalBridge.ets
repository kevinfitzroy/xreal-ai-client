import { Bytes } from '../util/Bytes';
import { Log } from '../util/Logger';

/**
 * JS→ArkTS 桥 —— 对齐 Android `TerminalBridge`(@JavascriptInterface)+ index.html 的 `window.Bridge.*` 契约。
 * 用 ArkWeb 的 `javaScriptProxy` 注册,name="Bridge",methodList = 下面所有方法。
 *
 * ⚠️ 线程模型差异(调研要点):ArkWeb 的 proxy 同步方法跑在 **ArkTS 主线程**(Android 是非 UI binder 线程)。
 *    `onInput` → SSH 写**绝不能在此直接阻塞**;PtyChannel.write 内部已派 taskpool 后台单线程(见 PtyChannel.ets 约束)。
 *
 * 方法签名严格匹配 index.html:openProject/onInput/onResize/voiceDown/voiceUp/vkeyEnter/vkeyEsc/goHome/hasHardwareKeyboard。
 * 本类只做「桥」—— 解 b64、转调注入的回调(由 Index 页装配),不含业务逻辑。
 */
const TAG = 'TerminalBridge';

export interface BridgeHandlers {
  openProject: (host: string, session: string, name: string, type: string) => void;
  writeInput: (data: Uint8Array) => void;            // 解 b64 后的裸字节 → 活动 PtyChannel
  resize: (cols: number, rows: number) => void;
  voiceDown: (lang: string) => void;
  voiceUp: (lang: string) => void;
  vkeyEnter: () => void;
  vkeyEsc: () => void;
  goHome: () => void;
  hasHardwareKeyboard: () => boolean;
}

export class TerminalBridge {
  static readonly JS_NAME = 'Bridge';
  static readonly METHOD_LIST = ['openProject', 'onInput', 'onResize', 'voiceDown', 'voiceUp',
    'vkeyEnter', 'vkeyEsc', 'goHome', 'hasHardwareKeyboard'];

  constructor(private h: BridgeHandlers) {}

  openProject(host: string, session: string, name: string, type: string): void {
    Log.i(TAG, `openProject ${host}/${session} (${type})`);
    this.h.openProject(host, session, name, type);
  }

  // index.html: Bridge.onInput(btoa(utf8(d)))。解 b64 → 裸字节,交给注入回调(内部后台写)。
  onInput(b64: string): void {
    try { this.h.writeInput(Bytes.fromB64(b64)); } catch (e) { Log.w(TAG, 'onInput ' + e); }
  }

  onResize(cols: number, rows: number): void { this.h.resize(cols, rows); }
  voiceDown(lang: string): void { this.h.voiceDown(lang); }
  voiceUp(lang: string): void { this.h.voiceUp(lang); }
  vkeyEnter(): void { this.h.vkeyEnter(); }
  vkeyEsc(): void { this.h.vkeyEsc(); }
  goHome(): void { this.h.goHome(); }

  // 同步返回 boolean(必须在 methodList,非 asyncMethodList)。index.html 启动时同步读。
  hasHardwareKeyboard(): boolean { return this.h.hasHardwareKeyboard(); }
}
