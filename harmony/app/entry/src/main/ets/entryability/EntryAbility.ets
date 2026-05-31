import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../util/Logger';
import { AppCtx } from '../util/AppCtx';

/**
 * 进程入口。职责对齐 Android `MainActivity.onCreate` 的「壳」部分:
 *   - 全屏沉浸(AR 眼镜要真全屏:隐藏状态栏 + 导航栏)
 *   - 暴露 application context 给后续 SSH/配置/日志(HarmonyOS 没有 Android 那种到处可取的 Context)
 *   - 运行时申请麦克风权限(语音用;user_grant 必须运行时弹)
 * 终端/列表/桥/SSH 全在 pages/Index.ets,与 Android 把逻辑塞进 Activity 不同 —— ArkUI 逻辑在页面组件里。
 */
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(_want: Want, _launch: AbilityConstant.LaunchParam): void {
    AppCtx.ability = this.context;   // 全局存一份,SSH/SettingsStore/AudioCapturer 用
    Log.i(TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const win: window.Window = windowStage.getMainWindowSync();
    // 沉浸式布局:内容延伸到状态栏/导航栏区域
    win.setWindowLayoutFullScreen(true).catch((e: BusinessError) => Log.w(TAG, 'layoutFullScreen ' + e.code));
    // 空数组 = 状态栏 + 导航栏全隐 → AR 眼镜真全屏
    win.setWindowSystemBarEnable([]).catch((e: BusinessError) => Log.w(TAG, 'systemBarEnable ' + e.code));
    // 保持常亮(终端场景不希望自动息屏;Beam Pro 上同诉求)
    win.setWindowKeepScreenOn(true).catch((e: BusinessError) => Log.w(TAG, 'keepScreenOn ' + e.code));

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) { Log.e(TAG, 'loadContent fail ' + JSON.stringify(err)); }
    });

    this.requestMicPermission();
  }

  /** 麦克风运行时权限(语音输入用)。失败不致命 —— 语音降级,SSH/终端照常(优雅降级,SPEC §9)。 */
  private requestMicPermission(): void {
    const atm = abilityAccessCtrl.createAtManager();
    atm.requestPermissionsFromUser(this.context as common.UIAbilityContext, ['ohos.permission.MICROPHONE'])
      .then((data) => {
        const ok = data.authResults.every((r) => r === 0);
        Log.i(TAG, 'mic permission granted=' + ok);
      })
      .catch((e: BusinessError) => Log.w(TAG, 'mic permission err ' + e.code));
  }

  onForeground(): void { Log.i(TAG, 'onForeground'); }
  onBackground(): void { Log.i(TAG, 'onBackground'); }
  onWindowStageDestroy(): void {}
  onDestroy(): void {}
}
