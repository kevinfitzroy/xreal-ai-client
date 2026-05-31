import { fileIo as fs } from '@kit.CoreFileKit';
import { HostConfig, ProxyConfig, AsrConfig } from '../model/Models';
import { AppCtx } from '../util/AppCtx';
import { Log } from '../util/Logger';

/**
 * 代客安装(Valet)+ 配置读取 —— 对齐 Android `SettingsStore`(SPEC §8)。**无设置 UI 是刻意设计**。
 *
 * 注入通道(HarmonyOS 落点,SPEC §8 矩阵):`hdc file send` → `/data/local/tmp/xreal_import/`
 *   { hosts.json, asr.json, <keys>.pem } → app 启动 importStagingIfPresent 拷进私有沙箱 → best-effort 清 staging。
 *   ⚠️ NEXT 沙箱对 /data/local/tmp 的 app 读权限各版本不一(见 HUMAN-TASKS.md),读不到时退路见该文档。
 *
 * 私有存储:filesDir/hosts.json + filesDir/keys/<name>.pem(0600 语义)+ filesDir/asr.json。
 */
const TAG = 'SettingsStore';
const STAGING = '/data/local/tmp/xreal_import';

export class SettingsStore {
  private static filesDir(): string { return AppCtx.get().filesDir; }

  /** 启动时调:若 staging 有配置,导入私有存储(原子写),然后 best-effort 清 staging。 */
  static importStagingIfPresent(): void {
    try {
      if (!fs.accessSync(STAGING)) { return; }
    } catch (e) { return; }
    const dir = SettingsStore.filesDir();
    SettingsStore.copyIfExists(`${STAGING}/hosts.json`, `${dir}/hosts.json`);
    SettingsStore.copyIfExists(`${STAGING}/asr.json`, `${dir}/asr.json`);
    // 私钥:hosts.json 里 key 是纯文件名;把同名 .pem 拷进 keys/
    try {
      const keysDir = `${dir}/keys`;
      if (!fs.accessSync(keysDir)) { fs.mkdirSync(keysDir); }
      for (const f of fs.listFileSync(STAGING)) {
        if (f.endsWith('.pem')) { SettingsStore.copyIfExists(`${STAGING}/${f}`, `${keysDir}/${f}`); }
      }
    } catch (e) { Log.w(TAG, 'keys import ' + e); }
    Log.i(TAG, 'staging imported');
  }

  /** 读 hosts(SPEC §8 两种顶层形态:数组 = legacy;对象 = {proxies,hosts})。无配置 → 空(走 mock)。 */
  static loadHosts(): HostConfig[] {
    const raw = SettingsStore.readText(`${SettingsStore.filesDir()}/hosts.json`);
    if (!raw) { return []; }
    try {
      const j: object = JSON.parse(raw);
      const hosts: HostConfig[] = Array.isArray(j) ? (j as HostConfig[]) : ((j as Record<string, Object>).hosts as HostConfig[] ?? []);
      // 私钥从 keys/<name>.pem 读进 privateKeyPem(防路径遍历:key 须纯文件名)
      for (const h of hosts) {
        if (h.key && !h.key.includes('/') && !h.key.includes('..')) {
          const pem = SettingsStore.readText(`${SettingsStore.filesDir()}/keys/${h.key}`);
          if (pem) { h.privateKeyPem = pem; }
        }
        if (!h.port) { h.port = 22; }
      }
      return hosts;
    } catch (e) { Log.w(TAG, 'loadHosts parse ' + e); return []; }
  }

  static loadProxies(): ProxyConfig[] {
    const raw = SettingsStore.readText(`${SettingsStore.filesDir()}/hosts.json`);
    if (!raw) { return []; }
    try {
      const j: object = JSON.parse(raw);
      return Array.isArray(j) ? [] : ((j as Record<string, Object>).proxies as ProxyConfig[] ?? []);
    } catch (e) { return []; }
  }

  static loadAsr(): AsrConfig | null {
    const raw = SettingsStore.readText(`${SettingsStore.filesDir()}/asr.json`);
    if (!raw) { return null; }
    try { return JSON.parse(raw) as AsrConfig; } catch (e) { return null; }
  }

  // ── fs helpers ──
  private static readText(path: string): string | null {
    try {
      if (!fs.accessSync(path)) { return null; }
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      return buffer8(buf);
    } catch (e) { Log.w(TAG, 'read ' + path + ' ' + e); return null; }
  }

  private static copyIfExists(src: string, dst: string): void {
    try {
      if (!fs.accessSync(src)) { return; }
      // 原子写:tmp → rename(SPEC §8 强制)
      const tmp = dst + '.tmp';
      fs.copyFileSync(src, tmp);
      fs.renameSync(tmp, dst);
    } catch (e) { Log.w(TAG, `copy ${src}→${dst} ${e}`); }
  }
}

function buffer8(buf: ArrayBuffer): string {
  const a = new Uint8Array(buf); let s = '';
  for (let i = 0; i < a.length; i++) { s += String.fromCharCode(a[i]); }
  return decodeURIComponent(escape(s));   // latin1→utf8
}
