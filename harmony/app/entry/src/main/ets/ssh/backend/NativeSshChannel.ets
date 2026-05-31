import { HostConfig } from '../../model/Models';
import { SshBackend, SshSession, PtyChannel, PtyDataSink } from '../PtyChannel';
import { Bytes } from '../../util/Bytes';
import { Log } from '../../util/Logger';
import taskpool from '@ohos.taskpool';

/**
 * 路径 A:libssh2 + NAPI 的 ArkTS 封装。对齐 Android sshj —— 「成熟 SSH 库 + 薄封装」。
 *
 * native 侧 = cpp/napi_init.cpp(封 libssh2:session/handshake/userauth_publickey/channel_*/direct_tcpip)。
 * 契约见 cpp/types/libsshbridge/index.d.ts。**.so 需交叉编译**(libssh2 + OpenSSL/mbedTLS,见 docs/ssh-options.md §A)。
 *
 * ⚠️ 启用步骤(默认未启用,以便纯 ArkTS 模式下工程能直接编译):
 *   1. 交叉编译 libssh2 → cpp/libs/arm64-v8a/libssh2.a(或 .so)
 *   2. entry/build-profile.json5 打开 externalNativeOptions
 *   3. entry/oh-package.json5 声明 "libsshbridge.so": "file:./src/main/cpp/types/libsshbridge"
 *   4. 取消下面 import 注释,删掉占位 `const nativeBridge = null`
 *   5. SshBackend.ets 的 BACKEND 改 'native'
 */

// import nativeBridge from 'libsshbridge.so';   // ← step 4 取消注释
const nativeBridge: SshBridge | null = null;     // 占位(.so build 前为 null → available()=false)

/** 与 cpp/types/libsshbridge/index.d.ts 对齐的 native 契约(本地复制一份,免依赖未 build 的 .so 模块)。 */
interface SshBridge {
  // 返回 native session 句柄(>0);失败抛。host/port/user + PEM 私钥 + 可选 viaHandle(在跳板上开 direct-tcpip)。
  connect(host: string, port: number, user: string, privateKeyPem: string, viaHandle: number): Promise<number>;
  // 开 PTY shell channel,返回 channel 句柄;startup 命令立即在 PTY 内执行。
  openShell(sessionHandle: number, cols: number, rows: number, startup: string): Promise<number>;
  // 阻塞读一段 PTY 输出(native 内部非阻塞 poll + 回 ArrayBuffer;EOF 回空)。在 taskpool 线程循环调。
  readChannel(channelHandle: number): Promise<ArrayBuffer>;
  writeChannel(channelHandle: number, data: ArrayBuffer): void;
  resizePty(channelHandle: number, cols: number, rows: number): void;
  closeChannel(channelHandle: number): void;
  // 短命 exec:跑命令拿全部 stdout。
  exec(sessionHandle: number, command: string): Promise<string>;
  closeSession(sessionHandle: number): void;
}

export class NativeSshBackend implements SshBackend {
  available(): boolean { return nativeBridge !== null; }

  async connect(host: HostConfig, viaSession: SshSession | null): Promise<SshSession> {
    if (!nativeBridge) { throw new Error('libsshbridge.so 未 build,native backend 不可用(见 NativeSshChannel 顶部步骤)'); }
    const viaHandle = (viaSession instanceof NativeSshSession) ? viaSession.handle : 0;
    const h = await nativeBridge.connect(host.host, host.port || 22, host.user, host.privateKeyPem ?? '', viaHandle);
    return new NativeSshSession(nativeBridge, h);
  }
}

class NativeSshSession implements SshSession {
  constructor(private bridge: SshBridge, readonly handle: number) {}

  async openShell(cols: number, rows: number, startup: string,
                  onData: PtyDataSink, onClose: () => void): Promise<PtyChannel> {
    const ch = await this.bridge.openShell(this.handle, cols, rows, startup);
    const channel = new NativePtyChannel(this.bridge, ch, onClose);
    channel.startReadLoop(onData);   // 后台 taskpool 循环读
    return channel;
  }

  exec(command: string): Promise<string> { return this.bridge.exec(this.handle, command); }
  close(): void { this.bridge.closeSession(this.handle); }
}

class NativePtyChannel implements PtyChannel {
  private closed = false;
  constructor(private bridge: SshBridge, private ch: number, private onClose: () => void) {}

  /** 后台读循环:native readChannel 非阻塞 poll,回 ArrayBuffer → onData。EOF/空 → 关。 */
  startReadLoop(onData: PtyDataSink): void {
    const pump = async (): Promise<void> => {
      while (!this.closed) {
        try {
          const buf = await this.bridge.readChannel(this.ch);
          if (buf.byteLength === 0) { break; }        // EOF
          onData(Bytes.u8(buf));
        } catch (e) { Log.w('NativePty', 'read err ' + e); break; }
      }
      if (!this.closed) { this.onClose(); }
    };
    pump();
  }

  // 写派后台:HarmonyOS 桥回调在主线程,直接写会卡 UI;且 sshj/libssh2 写缓冲非线程安全 → 必须串行后台。
  write(data: Uint8Array): void {
    if (this.closed) { return; }
    const ab: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    taskpool.execute((): void => { this.bridge.writeChannel(this.ch, ab); }).catch((e: Object) => Log.w('NativePty', 'write ' + e));
  }
  resize(cols: number, rows: number): void { if (!this.closed) { this.bridge.resizePty(this.ch, cols, rows); } }
  close(): void { if (this.closed) { return; } this.closed = true; this.bridge.closeChannel(this.ch); }
}
