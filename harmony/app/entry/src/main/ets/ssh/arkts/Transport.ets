import { socket } from '@kit.NetworkKit';
import { Log } from '../../util/Logger';

/**
 * 纯 ArkTS SSH(路径 B)的传输层:TCPSocket + SSH 二进制包帧(RFC 4253 §6)。
 * 这层**可以先写对**(TCPSocket 收发 ArrayBuffer 是确定 API);加密/MAC 钩子留给上层 KEX 后注入。
 *
 * SSH binary packet:  uint32 packet_length | byte padding_length | payload | padding | mac
 *   - KEX 前:明文,无 mac;
 *   - KEX 后:aes256-gcm@openssh.com → length 字段明文、payload+padding 加密、附 16B GCM tag(无独立 mac 字段)。
 * 这里实现明文帧 + 预留 encryptHook/decryptHook;GCM 接好后切换。
 */
const TAG = 'SshTransport';

type Resolver = (msg: Uint8Array) => void;

export class Transport {
  private tcp: socket.TCPSocket | null = null;
  private rxBuf: Uint8Array = new Uint8Array(0);
  private waiters: Resolver[] = [];     // 等待下一个完整包的 resolver 队列
  private seqIn = 0;
  private seqOut = 0;

  // KEX 后注入:把 payload 帧加密/解密。null = 明文阶段。
  encryptPacket: ((payload: Uint8Array, seq: number) => Promise<Uint8Array>) | null = null;
  decryptPacket: ((wire: Uint8Array, seq: number) => Promise<Uint8Array | null>) | null = null;

  async connect(host: string, port: number, timeoutMs: number): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    tcp.on('message', (info: socket.SocketMessageInfo) => this.onBytes(new Uint8Array(info.message)));
    tcp.on('close', () => { Log.i(TAG, 'tcp closed'); this.fail(); });
    tcp.on('error', (e: Object) => { Log.w(TAG, 'tcp error ' + JSON.stringify(e)); this.fail(); });
    await tcp.connect({ address: { address: host, port: port }, timeout: timeoutMs });
    await tcp.setExtraOptions({ TCPNoDelay: true });
    this.tcp = tcp;
  }

  /** 发送 SSH 版本串(明文,带 CRLF)。 */
  async sendRaw(data: Uint8Array): Promise<void> {
    if (!this.tcp) { throw new Error('not connected'); }
    await this.tcp.send({ data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) });
  }

  /** 发一个 SSH 包(payload = 不含长度/padding 的消息体,首字节是 SSH_MSG_* 号)。 */
  async sendPacket(payload: Uint8Array): Promise<void> {
    let wire: Uint8Array;
    if (this.encryptPacket) {
      wire = await this.encryptPacket(payload, this.seqOut);
    } else {
      wire = framePlain(payload);
    }
    this.seqOut = (this.seqOut + 1) >>> 0;
    await this.sendRaw(wire);
  }

  /** 等下一个完整 SSH 包(已解密的 payload)。 */
  recvPacket(): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve) => { this.waiters.push(resolve); this.drain(); });
  }

  /** 读 SSH 版本串(到第一个 \n)。 */
  recvLine(): Promise<string> {
    return new Promise<string>((resolve) => {
      const tryLine = (): boolean => {
        const nl = this.rxBuf.indexOf(0x0a);
        if (nl < 0) { return false; }
        const line = this.rxBuf.subarray(0, nl);
        this.rxBuf = this.rxBuf.subarray(nl + 1);
        let s = ''; for (let i = 0; i < line.length; i++) { if (line[i] !== 0x0d) { s += String.fromCharCode(line[i]); } }
        resolve(s); return true;
      };
      this.lineWaiter = tryLine;
      if (tryLine()) { this.lineWaiter = null; }
    });
  }
  private lineWaiter: (() => boolean) | null = null;

  private onBytes(chunk: Uint8Array): void {
    const merged = new Uint8Array(this.rxBuf.length + chunk.length);
    merged.set(this.rxBuf, 0); merged.set(chunk, this.rxBuf.length);
    this.rxBuf = merged;
    if (this.lineWaiter && this.lineWaiter()) { this.lineWaiter = null; }
    this.drain();
  }

  /** 尝试从 rxBuf 切出完整包,喂给等待者。 */
  private async drain(): Promise<void> {
    while (this.waiters.length > 0) {
      if (this.decryptPacket) {
        const payload = await this.decryptPacket(this.rxBuf, this.seqIn);
        if (!payload) { return; }                       // 数据不足
        // decryptPacket 内部应消费掉对应字节(通过 consume())。这里假定已 consume。
        this.seqIn = (this.seqIn + 1) >>> 0;
        (this.waiters.shift() as Resolver)(payload);
      } else {
        const r = unframePlain(this.rxBuf);
        if (!r) { return; }
        this.rxBuf = this.rxBuf.subarray(r.consumed);
        this.seqIn = (this.seqIn + 1) >>> 0;
        (this.waiters.shift() as Resolver)(r.payload);
      }
    }
  }

  /** 供 decryptPacket 回调消费已处理的 wire 字节。 */
  consume(n: number): void { this.rxBuf = this.rxBuf.subarray(n); }
  peek(): Uint8Array { return this.rxBuf; }

  private fail(): void {
    const ws = this.waiters; this.waiters = [];
    for (const w of ws) { try { (w as Resolver)(new Uint8Array(0)); } catch (e) {} }
  }

  close(): void { try { this.tcp?.close(); } catch (e) {} this.tcp = null; }
}

/** 明文帧:padding 至 8 字节对齐,padding_length ∈ [4,255]。 */
function framePlain(payload: Uint8Array): Uint8Array {
  const blockSize = 8;
  let padLen = blockSize - ((5 + payload.length) % blockSize);
  if (padLen < 4) { padLen += blockSize; }
  const packetLen = 1 + payload.length + padLen;
  const out = new Uint8Array(4 + packetLen);
  out[0] = (packetLen >>> 24) & 0xff; out[1] = (packetLen >>> 16) & 0xff;
  out[2] = (packetLen >>> 8) & 0xff;  out[3] = packetLen & 0xff;
  out[4] = padLen;
  out.set(payload, 5);
  // padding 应随机;KEX 前安全性无意义,先填 0(KEX 后走 GCM,padding 在加密区内)。TODO:随机填充。
  return out;
}

interface Unframed { payload: Uint8Array; consumed: number; }
function unframePlain(buf: Uint8Array): Unframed | null {
  if (buf.length < 4) { return null; }
  const packetLen = ((buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3]) >>> 0;
  if (buf.length < 4 + packetLen) { return null; }
  const padLen = buf[4];
  const payload = buf.subarray(5, 4 + packetLen - padLen);
  return { payload, consumed: 4 + packetLen };
}
