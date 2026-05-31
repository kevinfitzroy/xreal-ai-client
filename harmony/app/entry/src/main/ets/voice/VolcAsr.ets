import { webSocket } from '@kit.NetworkKit';
import { AsrConfig } from '../model/Models';
import { VolcFrame, VolcResult } from './VolcFrame';
import { Gzip } from './Gzip';
import { Bytes } from '../util/Bytes';
import { Log } from '../util/Logger';

/**
 * 豆包流式 ASR WebSocket 客户端 —— 对齐 Android `VolcEngineAsr` / iOS `VolcAsr`(SPEC §7)。
 * 会话式:open(连 WS + 发首帧配置)→ send(边录边发 gzip PCM 块)→ finish(负包拿 final)→ close。
 * 二进制帧走 VolcFrame;鉴权走 connect 的 header。race 防御 = generation 计数 + done/cancelled 标志。
 */
const TAG = 'VolcAsr';
const ENDPOINT = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async';

export interface AsrCallbacks {
  onPartial: (text: string) => void;
  onFinal: (text: string) => void;
  onError: (msg: string) => void;
}

export class VolcAsr {
  private ws: webSocket.WebSocket | null = null;
  private gen = 0;
  private done = false;
  private cancelled = false;

  async open(cfg: AsrConfig, hotwords: string[], cb: AsrCallbacks): Promise<void> {
    const myGen = ++this.gen;
    this.done = false; this.cancelled = false;
    this.ws = webSocket.createWebSocket();

    this.ws.on('message', (_e: Object, data: string | ArrayBuffer) => {
      if (myGen !== this.gen || this.cancelled) { return; }
      if (data instanceof ArrayBuffer) { this.onFrame(new Uint8Array(data), cb); }
    });
    this.ws.on('error', (e: Object) => { if (!this.cancelled) { cb.onError('ws ' + JSON.stringify(e)); } });
    this.ws.on('close', () => Log.i(TAG, 'ws closed'));

    await this.ws.connect(ENDPOINT, {
      header: {
        'X-Api-App-Key': cfg.appid,
        'X-Api-Access-Key': cfg.token,
        'X-Api-Resource-Id': cfg.resourceId,
        'X-Api-Connect-Id': 'xreal-harmony'
      }
    } as webSocket.WebSocketRequestOptions);

    // 首帧:full-client-request(JSON 配置 + 热词,gzip)
    const reqJson = JSON.stringify({
      user: { uid: 'xreal' },
      audio: { format: 'pcm', rate: 16000, bits: 16, channel: 1 },
      request: { model_name: 'bigmodel', enable_punc: true, corpus: { context: hotwords.join(' ') } }
    });
    const frame = VolcFrame.fullClient(await Gzip.compress(Bytes.utf8(reqJson)));
    await this.sendBin(frame);
  }

  /** 发一块 PCM(gzip + audio frame)。 */
  async send(pcm: Uint8Array): Promise<void> {
    if (this.done || this.cancelled || !this.ws) { return; }
    const frame = VolcFrame.audio(await Gzip.compress(pcm), false);
    await this.sendBin(frame);
  }

  /** 收尾:发负包(last packet),等 final。 */
  async finish(): Promise<void> {
    if (this.done || this.cancelled || !this.ws) { return; }
    this.done = true;
    const frame = VolcFrame.audio(await Gzip.compress(new Uint8Array(0)), true);
    await this.sendBin(frame);
  }

  cancel(): void {
    this.cancelled = true; this.gen++;
    try { this.ws?.close(); } catch (e) {}
    this.ws = null;
  }

  private async sendBin(frame: Uint8Array): Promise<void> {
    try { await this.ws?.send(frame.buffer.slice(frame.byteOffset, frame.byteOffset + frame.byteLength)); }
    catch (e) { Log.w(TAG, 'send ' + e); }
  }

  private async onFrame(data: Uint8Array, cb: AsrCallbacks): Promise<void> {
    const r: VolcResult | null = VolcFrame.parse(data);
    if (!r) { return; }
    if (r.type === 'error') { cb.onError('volc error'); return; }
    if (r.type !== 'response') { return; }   // 事件帧已在 parse 跳过 event;unknown 安全忽略
    try {
      const jsonBytes = r.gzip ? await Gzip.decompress(r.payload) : r.payload;
      const obj = JSON.parse(Bytes.str(jsonBytes)) as Record<string, Object>;
      const text = VolcAsr.extractText(obj);
      if (text !== null) {
        if (r.isLast) { cb.onFinal(text); } else { cb.onPartial(text); }
      }
    } catch (e) { Log.w(TAG, 'parse payload ' + e); }
  }

  /** 从豆包响应 JSON 抽转写文本(result[].text)。形状随版本微调,真机核。 */
  private static extractText(obj: Record<string, Object>): string | null {
    const result = obj.result as Record<string, Object> | undefined;
    if (!result) { return null; }
    const text = result.text as string | undefined;
    return text ?? null;
  }
}
