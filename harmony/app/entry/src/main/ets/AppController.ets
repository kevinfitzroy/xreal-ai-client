import { webview } from '@kit.ArkWeb';
import { HostConfig, AsrConfig, ProjectType, isAiAgent } from './model/Models';
import { SettingsStore } from './config/SettingsStore';
import { ManifestFetcher } from './manifest/ManifestFetcher';
import { SshConnection, tmuxAttachCommand, TMUX_CONF } from './ssh/SshConnection';
import { PtyChannel } from './ssh/PtyChannel';
import { TermJs } from './terminal/TermJs';
import { BridgeHandlers } from './bridge/TerminalBridge';
import { VoiceController, VoiceHost } from './voice/VoiceController';
import { Bytes } from './util/Bytes';
import { Log } from './util/Logger';

/**
 * 编排核心 —— 对齐 Android `MainActivity` 的业务逻辑部分(非 UI 壳)。
 * 实现 BridgeHandlers(JS→ArkTS 桥回调)+ VoiceHost(语音宿主),把列表/终端/SSH/语音串起来。
 * Index.ets 只是 ArkUI 壳:装 Web + 抢键 + 生命周期,把事件转给本类。
 */
const TAG = 'AppController';

export class AppController implements BridgeHandlers, VoiceHost {
  private termJs: TermJs;
  private voice: VoiceController;
  private hosts: HostConfig[] = [];
  private hostsByName = new Map<string, HostConfig>();
  private asr: AsrConfig | null = null;

  private conn: SshConnection | null = null;
  private channel: PtyChannel | null = null;
  private currentType: ProjectType = 'ssh';
  private openSeq = 0;          // 防 open→back→open 错绑(对齐 Android openSeq）
  private hwKeyboard = false;
  private lastCols = 80; private lastRows = 24;

  constructor(private controller: webview.WebviewController) {
    this.termJs = new TermJs(controller);
    this.voice = new VoiceController(this);
  }

  /** 页面就绪后调:导入 Valet 配置、读 hosts/asr、首次拉列表。 */
  async onReady(): Promise<void> {
    SettingsStore.importStagingIfPresent();
    this.hosts = SettingsStore.loadHosts();
    this.asr = SettingsStore.loadAsr();
    for (const h of this.hosts) { this.hostsByName.set(h.name, h); }
    Log.i(TAG, `loaded ${this.hosts.length} hosts`);
    await this.refreshList();
  }

  /** 事件驱动刷新(首显 / back / onForeground 各一次,零空轮询)。空 hosts → 保留 index.html mock。 */
  async refreshList(): Promise<void> {
    if (this.hosts.length === 0) { return; }
    try {
      const json = await new ManifestFetcher(this.hosts).fetchAll();
      this.termJs.setHosts(json);
    } catch (e) { Log.w(TAG, 'refreshList ' + e); }   // 失败保留当前列表
  }

  // ────────── BridgeHandlers(JS→ArkTS)──────────

  async openProject(hostName: string, session: string, name: string, type: string): Promise<void> {
    const mySeq = ++this.openSeq;
    const host = this.hostsByName.get(hostName);
    this.currentType = (type as ProjectType);
    this.termJs.showTerminal(name, type);
    if (!host) { Log.w(TAG, `host 未配置(mock?): ${hostName}`); return; }   // mock host → index.html 自切

    // 关旧通道
    try { this.channel?.close(); } catch (e) {}
    this.channel = null;
    this.conn?.close();
    this.conn = new SshConnection();
    try {
      await this.conn.connect(host, this.hostsByName);
      if (mySeq !== this.openSeq) { this.conn.close(); return; }            // 快速切走了
      const confB64 = Bytes.toB64(Bytes.utf8(TMUX_CONF));
      const startup = tmuxAttachCommand(session, confB64);
      const ch = await this.conn.openShell(this.lastCols, this.lastRows, startup,
        (data) => { if (mySeq === this.openSeq) { this.termJs.writeToTerm(data); } },
        () => { Log.i(TAG, 'channel closed'); });
      if (mySeq !== this.openSeq) { ch.close(); return; }
      this.channel = ch;
      this.termJs.syncSize();   // 把当前 xterm 尺寸重推新通道(否则 PTY 停 80x24)
    } catch (e) {
      Log.e(TAG, `openProject ${hostName}/${session} 失败: ${e}`);
      this.termJs.writeToTerm(Bytes.utf8(`\r\n[连接失败] ${e}\r\n`));   // 优雅降级:提示不崩
    }
  }

  writeInput(data: Uint8Array): void { this.channel?.write(data); }       // 内部后台单线程
  resize(cols: number, rows: number): void { this.lastCols = cols; this.lastRows = rows; this.channel?.resize(cols, rows); }
  voiceDown(lang: string): void { this.voice.onVoiceDown(lang); }
  voiceUp(lang: string): void { this.voice.onVoiceUp(lang); }
  vkeyEnter(): void { this.writeInput(Bytes.utf8('\r')); }
  vkeyEsc(): void { this.writeInput(Bytes.utf8('\x1b')); }
  goHome(): void {
    try { this.channel?.close(); } catch (e) {}
    this.channel = null; this.conn?.close(); this.conn = null;
    this.termJs.showList();
    this.refreshList();
  }
  hasHardwareKeyboard(): boolean { return this.hwKeyboard; }

  // ────────── VoiceHost ──────────

  asrConfig(): AsrConfig | null { return this.asr; }
  hotwordsForCurrent(): string[] | undefined { return undefined; }   // TODO:接当前 project 的 manifest hotwords
  currentIsAiAgent(): boolean { return isAiAgent(this.currentType); }
  injectText(text: string): void { this.writeInput(Bytes.utf8(text)); }
  overlay(status: string, text: string): void { this.termJs.showOverlay(status, text); }
  hideOverlay(): void { this.termJs.hideOverlay(); }

  // ────────── KeyRouter actions / 外接键盘 ──────────

  onKeyboardChange(present: boolean): void { this.hwKeyboard = present; this.termJs.setHwKeyboard(present); }
  pageUp(): void { this.writeInput(Bytes.utf8('\x1b[1;2A')); }     // Shift+Up → tmux S-Up 绑定(copy-mode 半页)
  pageDown(): void { this.writeInput(Bytes.utf8('\x1b[1;2B')); }
  back(): void { this.goHome(); }

  onForeground(): void { this.refreshList(); }
}
