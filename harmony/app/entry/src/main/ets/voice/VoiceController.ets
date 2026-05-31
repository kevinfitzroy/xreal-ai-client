import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { AsrConfig } from '../model/Models';
import { AudioCapturer } from './AudioCapturer';
import { VolcAsr } from './VolcAsr';
import { Hotwords } from './Hotwords';
import { AppCtx } from '../util/AppCtx';
import { Log } from '../util/Logger';

/**
 * 语音状态机 —— 对齐 Android `VoiceDaemon`(hold-to-talk,SPEC §4/§6)。
 *   voiceDown → 起长时任务保活 + AudioCapturer + VolcAsr.open;overlay 显示中间结果
 *   voiceUp   → 停录 + VolcAsr.finish;final 文本注入活动 PtyChannel(AI-agent 类加 🎤 前缀)
 *
 * 注入走 host.injectText → PtyChannel.write(后台单线程,SPEC §4 硬约束)。语音路径不需知道 xterm 存在。
 */
const TAG = 'VoiceController';
const MIC_PREFIX = '🎤 ';   // 🎤 + 空格(SPEC §4:AI-agent 类前缀)

export interface VoiceHost {
  asrConfig(): AsrConfig | null;
  hotwordsForCurrent(): string[] | undefined;   // 当前 project 的 manifest hotwords
  currentIsAiAgent(): boolean;                   // 决定是否加 🎤 前缀(ssh 类不加)
  injectText(text: string): void;                // 写活动 PtyChannel
  overlay(status: string, text: string): void;   // window.showOverlay
  hideOverlay(): void;
}

type State = 'idle' | 'recording';

export class VoiceController {
  private state: State = 'idle';
  private cap = new AudioCapturer();
  private asr = new VolcAsr();
  private lastText = '';

  constructor(private host: VoiceHost) {}

  async onVoiceDown(_lang: string): Promise<void> {
    if (this.state === 'recording') { return; }
    const cfg = this.host.asrConfig();
    if (!cfg) { this.host.overlay('🎤 语音不可用', '未配置 ASR 凭证(Valet asr.json)'); return; }
    this.state = 'recording';
    this.lastText = '';
    await this.startBackgroundTask();
    this.host.overlay('🎤 录音中…', '');

    const hotwords = Hotwords.merge(this.host.hotwordsForCurrent());
    await this.asr.open(cfg, hotwords, {
      onPartial: (t) => { this.lastText = t; this.host.overlay('🎤 录音中…', t); },
      onFinal: (t) => { this.lastText = t; },
      onError: (m) => { Log.w(TAG, 'asr ' + m); }
    });
    await this.cap.start((pcm) => { this.asr.send(pcm); });
  }

  async onVoiceUp(_lang: string): Promise<void> {
    if (this.state !== 'recording') { return; }
    this.state = 'idle';
    await this.cap.stop();
    await this.asr.finish();
    // 给 final 一点到达时间;简化:用 lastText(partial 兜底)。真机可加短等待 final。
    const text = this.lastText.trim();
    this.host.hideOverlay();
    if (text.length > 0) {
      const out = this.host.currentIsAiAgent() ? (MIC_PREFIX + text) : text;
      this.host.injectText(out);
    }
    this.asr.cancel();
    await this.stopBackgroundTask();
  }

  // ── 长时任务(前台 Service 等价物,录音保活)──
  private async startBackgroundTask(): Promise<void> {
    try {
      const ctx = AppCtx.get();
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'io.github.kevinfitzroy.xrealclient', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx, backgroundTaskManager.BackgroundMode.AUDIO_RECORDING, agent);
    } catch (e) { Log.w(TAG, 'startBg ' + e); }
  }

  private async stopBackgroundTask(): Promise<void> {
    try { await backgroundTaskManager.stopBackgroundRunning(AppCtx.get()); } catch (e) {}
  }
}
