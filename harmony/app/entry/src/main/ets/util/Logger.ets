import { hilog } from '@kit.PerformanceAnalysisKit';

// 统一日志。domain=0xE51A('xreal'),tag 见各调用点。
// 看日志:`hdc hilog`,过滤 `hdc shell hilog -T <tag>`。对应 Android 的 AppLog/logcat。
const DOMAIN = 0xE51A;

export class Log {
  static i(tag: string, msg: string): void { hilog.info(DOMAIN, tag, '%{public}s', msg); }
  static w(tag: string, msg: string): void { hilog.warn(DOMAIN, tag, '%{public}s', msg); }
  static e(tag: string, msg: string): void { hilog.error(DOMAIN, tag, '%{public}s', msg); }
  static d(tag: string, msg: string): void { hilog.debug(DOMAIN, tag, '%{public}s', msg); }
}
