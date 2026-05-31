import { common } from '@kit.AbilityKit';

/**
 * 全局持有 ability context。HarmonyOS 没有 Android `Context` 那种到处能拿的对象,
 * 但 SettingsStore(读沙箱/临时区)、AudioCapturer、backgroundTaskManager 都需要 context。
 * EntryAbility.onCreate 里赋值一次,其余模块按需取。
 */
export class AppCtx {
  static ability: common.UIAbilityContext | null = null;

  static get(): common.UIAbilityContext {
    if (!AppCtx.ability) { throw new Error('AppCtx not initialized (EntryAbility.onCreate 未跑?)'); }
    return AppCtx.ability;
  }
}
