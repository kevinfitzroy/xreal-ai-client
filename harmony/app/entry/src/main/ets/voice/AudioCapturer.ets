import { audio } from '@kit.AudioKit';
import { Log } from '../util/Logger';

/**
 * 麦克风录音 —— 对齐 Android `AudioRecorder`(16kHz / mono / S16LE 裸 PCM)。
 * `on('readData')` 边录边吐 PCM ArrayBuffer;系统回调粒度常为 20/40ms,自己攒到 ~200ms 再发(对齐 Android 切片)。
 */
const TAG = 'AudioCapturer';
const CHUNK_BYTES = 6400;   // 16000 * 0.2s * 2B = 200ms @ 16k/mono/16bit

export type PcmSink = (pcm: Uint8Array) => void;

export class AudioCapturer {
  private cap: audio.AudioCapturer | null = null;
  private pending: number[] = [];   // 攒包缓冲(字节)
  private onChunk: PcmSink | null = null;

  async start(onChunk: PcmSink): Promise<void> {
    this.onChunk = onChunk;
    this.pending = [];
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 };
    this.cap = await audio.createAudioCapturer({ streamInfo, capturerInfo });
    this.cap.on('readData', (buffer: ArrayBuffer) => this.feed(new Uint8Array(buffer)));
    await this.cap.start();
    Log.i(TAG, 'started');
  }

  private feed(pcm: Uint8Array): void {
    for (let i = 0; i < pcm.length; i++) { this.pending.push(pcm[i]); }
    while (this.pending.length >= CHUNK_BYTES) {
      const chunk = new Uint8Array(this.pending.splice(0, CHUNK_BYTES));
      this.onChunk?.(chunk);
    }
  }

  /** 停止并 flush 残余(松手时把不足 200ms 的尾巴也发出去)。 */
  async stop(): Promise<void> {
    try {
      if (this.pending.length > 0) { this.onChunk?.(new Uint8Array(this.pending.splice(0))); }
      await this.cap?.stop();
      await this.cap?.release();
    } catch (e) { Log.w(TAG, 'stop ' + e); }
    this.cap = null; this.onChunk = null;
    Log.i(TAG, 'stopped');
  }
}
