/**
 * 豆包(VolcEngine)流式 ASR 二进制协议帧 —— 对齐 Android `VolcFrame`(有 JVM 单测)。
 * 4 字节 header:
 *   byte0: (protocolVersion<<4) | headerSize(以 4 字节为单位,通常 1)
 *   byte1: (messageType<<4) | messageTypeSpecificFlags
 *   byte2: (serialization<<4) | compression
 *   byte3: reserved(0)
 * 之后:[可选 event int32][可选 payload size uint32 + payload]
 *
 * messageType: 0b0001=full-client-request, 0b0010=audio-only-request,
 *              0b1001=full-server-response, 0b1111=error
 * flags: bit0=last package(负包), bit2(=4)=with-event(火山 v3 事件帧)
 * serialization: 0b0001=JSON;compression: 0b0001=gzip
 */
export const MsgType = { FullClient: 0b0001, AudioOnly: 0b0010, ServerResponse: 0b1001, Error: 0b1111 };
export const Flags = { None: 0, LastPacket: 0b0001, WithEvent: 0b0100 };
const SER_JSON = 0b0001, COMP_GZIP = 0b0001;

export class VolcFrame {
  /** 构造 full-client-request(首帧,带 JSON 配置,gzip 压缩)。 */
  static fullClient(gzippedJson: Uint8Array): Uint8Array {
    return VolcFrame.build(MsgType.FullClient, Flags.None, gzippedJson);
  }

  /** 构造 audio-only-request(音频块;last=true 时为负包/收尾)。 */
  static audio(gzippedPcm: Uint8Array, last: boolean): Uint8Array {
    return VolcFrame.build(MsgType.AudioOnly, last ? Flags.LastPacket : Flags.None, gzippedPcm);
  }

  private static build(msgType: number, flags: number, payload: Uint8Array): Uint8Array {
    const out = new Uint8Array(4 + 4 + payload.length);
    out[0] = (0b0001 << 4) | 0b0001;          // protocol v1, header size 1
    out[1] = (msgType << 4) | flags;
    out[2] = (SER_JSON << 4) | COMP_GZIP;
    out[3] = 0;
    const n = payload.length;
    out[4] = (n >>> 24) & 0xff; out[5] = (n >>> 16) & 0xff; out[6] = (n >>> 8) & 0xff; out[7] = n & 0xff;
    out.set(payload, 8);
    return out;
  }

  /**
   * 解析服务端响应帧。返回 { type, isLast, payload(gzipped or raw) }。
   * ⚠️ 火山 v3 事件帧 flags 含 WithEvent(bit2=4):header 后多一个 int32 event 字段,
   *    不跳过会把 event 当 payload size 读 → 越界(Android 踩过的 bug,这里加边界保护)。
   */
  static parse(data: Uint8Array): VolcResult | null {
    if (data.length < 4) { return null; }
    const headerSize = (data[0] & 0x0f) * 4;
    const msgType = (data[1] >>> 4) & 0x0f;
    const flags = data[1] & 0x0f;
    const compression = data[2] & 0x0f;
    let off = headerSize;
    if (flags & Flags.WithEvent) { off += 4; }   // 跳过 event int32(关键边界保护)
    if (msgType === MsgType.Error) {
      // error: [code uint32][msg size uint32][msg]
      return { type: 'error', isLast: true, payload: data.subarray(off), gzip: compression === COMP_GZIP };
    }
    if (off + 4 > data.length) { return null; }
    const size = ((data[off] << 24) | (data[off + 1] << 16) | (data[off + 2] << 8) | data[off + 3]) >>> 0;
    off += 4;
    const payload = data.subarray(off, off + size);
    return {
      type: msgType === MsgType.ServerResponse ? 'response' : 'unknown',
      isLast: (flags & Flags.LastPacket) !== 0,
      payload,
      gzip: compression === COMP_GZIP
    };
  }
}

export interface VolcResult {
  type: 'response' | 'error' | 'unknown';
  isLast: boolean;
  payload: Uint8Array;   // JSON(可能 gzip);上层按 gzip 标志解压再 JSON.parse
  gzip: boolean;
}
