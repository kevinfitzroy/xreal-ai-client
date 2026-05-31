import { inputDevice } from '@kit.InputKit';
import { Log } from '../util/Logger';

/**
 * 物理键路由 + 外接键盘检测 —— 对齐 Android `MainActivity.dispatchKeyEvent` + 虚拟键盘显隐。
 *
 * 语义(SPEC §6):F1=语音 hold-to-talk(Down 起录/Up 停录,KeyType 区分)、F2=返回、Shift+↑/↓=翻页。
 * ⚠️ HarmonyOS 是**组件焦点级** onKeyEvent(非 Activity 全局)→ Index 根容器须 focusable+defaultFocus 抢焦。
 * ⚠️ 8BitDo 在鸿蒙设备实际映射到哪个 KeyCode **需真机打 log 验**(与 Beam Pro 的 Generic.kl 不保证一致);
 *    下面数值是 HarmonyOS 标准 KeyCode(F1=2090),真机若不符按 log 调整。
 */
const TAG = 'KeyRouter';

// HarmonyOS KeyCode(@ohos.multimodalInput.keyCode)。注意 ≠ Android keycode。
const KC = {
  F1: 2090, F2: 2091,
  DPAD_UP: 2012, DPAD_DOWN: 2013, DPAD_LEFT: 2014, DPAD_RIGHT: 2015,
  SHIFT_L: 2047, SHIFT_R: 2048
};
// KeyType(ArkUI):Down=0 / Up=1
const DOWN = 0, UP = 1;

export interface KeyActions {
  voiceDown: () => void;
  voiceUp: () => void;
  back: () => void;          // 返回列表 / 退层
  pageUp: () => void;
  pageDown: () => void;
}

export class KeyRouter {
  constructor(private a: KeyActions) {}

  /** 在 Index 根容器的 onKeyEvent 里调。返回 true = 已消费(吃掉,不透传 Web)。 */
  handle(keyCode: number, keyType: number, metaKey: number): boolean {
    const shift = (metaKey & 0x1) !== 0;   // metaKey bit0 ~ Shift(真机核)
    switch (keyCode) {
      case KC.F1:
        if (keyType === DOWN) { this.a.voiceDown(); } else if (keyType === UP) { this.a.voiceUp(); }
        return true;
      case KC.F2:
        if (keyType === DOWN) { this.a.back(); }
        return true;
      case KC.DPAD_UP:
        if (shift && keyType === DOWN) { this.a.pageUp(); return true; }
        return false;   // 非 Shift:让 Web/xterm 自己处理(列表导航 / 终端方向键)
      case KC.DPAD_DOWN:
        if (shift && keyType === DOWN) { this.a.pageDown(); return true; }
        return false;
      default:
        return false;
    }
  }

  /** 监听外接键盘插拔 → onChange(present)。Android 用 Configuration.keyboard,这里用 inputDevice。 */
  watchKeyboard(onChange: (present: boolean) => void): void {
    const refresh = async (): Promise<void> => {
      try {
        const ids = await inputDevice.getDeviceList();
        let kb = false;
        for (const id of ids) {
          const kt = await inputDevice.getKeyboardType(id);
          if (kt === inputDevice.KeyboardType.ALPHABETIC_KEYBOARD) { kb = true; break; }
        }
        onChange(kb);
      } catch (e) { Log.w(TAG, 'kb enum ' + e); }
    };
    inputDevice.on('change', (_d: inputDevice.DeviceListener) => { refresh(); });
    refresh();   // 启动枚举一遍
  }
}
