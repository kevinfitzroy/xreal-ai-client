import { HostConfig } from '../../model/Models';
import { SshBackend, SshSession, PtyChannel, PtyDataSink } from '../PtyChannel';
import { Transport } from '../arkts/Transport';
import { SshCrypto } from '../arkts/SshCrypto';
import { SshWriter, SshReader, utf8 } from '../arkts/SshWire';
import { Log } from '../../util/Logger';

/**
 * 路径 B:纯 ArkTS SSH(over TCPSocket + cryptoFramework)。零 native、100% 可审计。
 * 对标 iOS 的 Citadel(纯语言层)。**协议栈是手搓的,本文件是骨架** —— 版本交换 + KEXINIT 构造已实,
 * curve25519 KEX 派生 / GCM 接线 / OpenSSH 私钥解析 / channel 多路复用标了 TODO,需有环境逐段补齐 + 真机验。
 *
 * 算法集(对齐 SPEC §5「客户端一律 ed25519」+ API 12 基线):
 *   KEX        curve25519-sha256
 *   host key   ssh-ed25519
 *   cipher/MAC aes256-gcm@openssh.com(GCM 自带认证,无独立 MAC;chacha20 要 API22+ 故不用)
 *   pubkey     ssh-ed25519(客户端私钥)
 */
const TAG = 'ArkSsh';
const CLIENT_ID = 'SSH-2.0-XrealHarmony_0.1';

// SSH 消息号(RFC 4253/4252/4254)
const MSG = {
  DISCONNECT: 1, IGNORE: 2, SERVICE_REQUEST: 5, SERVICE_ACCEPT: 6,
  KEXINIT: 20, NEWKEYS: 21, KEX_ECDH_INIT: 30, KEX_ECDH_REPLY: 31,
  USERAUTH_REQUEST: 50, USERAUTH_FAILURE: 51, USERAUTH_SUCCESS: 52,
  CHANNEL_OPEN: 90, CHANNEL_OPEN_CONFIRMATION: 91, CHANNEL_OPEN_FAILURE: 92,
  CHANNEL_WINDOW_ADJUST: 93, CHANNEL_DATA: 94, CHANNEL_EOF: 96, CHANNEL_CLOSE: 97,
  CHANNEL_REQUEST: 98, CHANNEL_SUCCESS: 99, CHANNEL_FAILURE: 100
};

export class ArkSshBackend implements SshBackend {
  available(): boolean { return true; }   // 纯 ArkTS 永远「可用」(但协议未完成时 connect 会抛)

  async connect(host: HostConfig, viaSession: SshSession | null): Promise<SshSession> {
    if (viaSession) {
      // 多跳:在跳板 session 上开 direct-tcpip channel 当作 socket，再在其上跑完整 SSH 握手。
      // TODO(路径 B):direct-tcpip channel 作为 Transport 的底层流(Citadel jump 等价物)。
      throw new Error('NotImplemented: 纯 ArkTS 多跳(via)需 direct-tcpip channel,见 DECISIONS.md D1');
    }
    const s = new ArkSshSession(host);
    await s.handshake();
    return s;
  }
}

class ArkSshSession implements SshSession {
  private t = new Transport();
  private sessionId: Uint8Array | null = null;

  constructor(private host: HostConfig) {}

  async handshake(): Promise<void> {
    await this.t.connect(this.host.host, this.host.port || 22, 12000);

    // ── 1. 版本交换(RFC 4253 §4.2)──
    await this.t.sendRaw(utf8(CLIENT_ID + '\r\n'));
    let serverId = '';
    do { serverId = await this.t.recvLine(); } while (!serverId.startsWith('SSH-'));   // 跳过 banner 行
    Log.i(TAG, 'server: ' + serverId);

    // ── 2. KEXINIT(RFC 4253 §7.1)── 构造 + 发送(真实)
    const clientKexInit = this.buildKexInit();
    await this.t.sendPacket(clientKexInit);
    const serverKexInit = await this.t.recvPacket();
    if (serverKexInit[0] !== MSG.KEXINIT) { throw new Error('期望 KEXINIT,得到 ' + serverKexInit[0]); }

    // ── 3. curve25519-sha256 KEX(RFC 5656 + curve25519-sha256)──
    await this.doKex(serverId, clientKexInit, serverKexInit);

    // ── 4. 认证(RFC 4252 publickey,ssh-ed25519)──
    await this.authPublicKey();
  }

  /** 构造 SSH_MSG_KEXINIT(算法协商列表)。 */
  private buildKexInit(): Uint8Array {
    const w = new SshWriter();
    w.byte(MSG.KEXINIT);
    // cookie 16B(应随机;Math.random 在 workflow 禁用,运行时用 cryptoFramework rand。骨架先填 0)
    w.raw(new Uint8Array(16));
    w.nameList(['curve25519-sha256', 'curve25519-sha256@libssh.org']);  // kex
    w.nameList(['ssh-ed25519']);                                         // server host key
    w.nameList(['aes256-gcm@openssh.com']);                              // enc c→s
    w.nameList(['aes256-gcm@openssh.com']);                              // enc s→c
    w.nameList(['hmac-sha2-256']);                                       // mac c→s(GCM 下被忽略)
    w.nameList(['hmac-sha2-256']);                                       // mac s→c
    w.nameList(['none']);                                                // compress c→s
    w.nameList(['none']);                                                // compress s→c
    w.nameList([]); w.nameList([]);                                      // languages
    w.bool(false);                                                       // first_kex_packet_follows
    w.uint32(0);                                                         // reserved
    return w.build();
  }

  private async doKex(_serverId: string, _clientKexInit: Uint8Array, serverKexInit: Uint8Array): Promise<void> {
    // 3a. 生成 X25519 临时对 + 发 KEX_ECDH_INIT(含客户端公钥 Q_C)
    //     —— 这里需先拿到对端公钥才能算共享密钥,SSH 顺序是:先发 INIT(只带 Q_C),再收 REPLY(带 Q_S + hostkey + sig)。
    // TODO(路径 B):X25519 临时密钥对的 Q_C 提取依赖 SshCrypto.x25519* 的 raw 编码核准(见 SshCrypto TODO)。
    Log.i(TAG, 'KEX server algs len=' + serverKexInit.length);

    // 3b. 收 KEX_ECDH_REPLY → 解出 Q_S、host key、签名
    // 3c. 算共享密钥 K = X25519(privC, Q_S);算 exchange hash H = SHA256(V_C||V_S||I_C||I_S||K_S||Q_C||Q_S||K)
    // 3d. ed25519 验签:SshCrypto.ed25519Verify(hostEd25519Pub, H, sig);TOFU 记录 host key
    // 3e. sessionId = H(首次);派生 keys:K1=HASH(K||H||"A"||sessionId)... (RFC 4253 §7.2)
    // 3f. 发 NEWKEYS,装 GCM 加解密钩子到 transport(this.t.encryptPacket/decryptPacket)
    throw new Error('NotImplemented: curve25519 KEX 派生 + GCM 接线(ArkSshSession.doKex 骨架)。见 docs/ssh-options.md §B 完成清单');
  }

  private async authPublicKey(): Promise<void> {
    // 1. SERVICE_REQUEST "ssh-userauth" → SERVICE_ACCEPT
    // 2. USERAUTH_REQUEST(user, "ssh-connection", "publickey", true, "ssh-ed25519", pubblob, signature)
    //    签名数据 = string(sessionId) + 整个 request(不含 sig)。SshCrypto.ed25519Sign(privKey, data)
    // TODO(路径 B):OpenSSH ed25519 私钥(host.privateKeyPem)解析成 cryptoFramework 私钥(SshKeyParser)。
    throw new Error('NotImplemented: publickey 认证(ArkSshSession.authPublicKey 骨架)');
  }

  async openShell(_cols: number, _rows: number, _startup: string,
                  _onData: PtyDataSink, _onClose: () => void): Promise<PtyChannel> {
    // CHANNEL_OPEN "session" → pty-req(term=xterm-256color, cols/rows)→ exec/shell → CHANNEL_DATA 双向
    throw new Error('NotImplemented: channel 层(openShell 骨架)');
  }

  async exec(_command: string): Promise<string> {
    throw new Error('NotImplemented: channel 层(exec 骨架)');
  }

  close(): void { this.t.close(); }
}
