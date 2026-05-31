import { HostConfig } from '../model/Models';

/**
 * SSH 抽象层 —— 对齐 Android `PtyChannel` + `SshConnection`。两条 backend(libssh2/NAPI、纯 ArkTS)都实现这组接口,
 * 上层(终端桥、ManifestFetcher、语音注入)不关心底层是哪条路。**选哪条路是悬置的人工决策**,见 docs/ssh-options.md。
 *
 * 硬约束(跨端,见 SPEC §4 + memory input-path-constraints):
 *   - `write` 必须在**后台单线程**执行;HarmonyOS 桥回调跑在 UI 主线程,绝不能在桥里直接阻塞写。
 *     backend 内部用 TaskPool / 自有 worker 串行化写,与 Android「SSH 写入必须后台单线程」同源。
 */

/** PTY 输出流回调:远端字节到达时调(已是裸字节,非 b64)。 */
export type PtyDataSink = (data: Uint8Array) => void;

/** 一条活动的交互式 PTY 通道(attach tmux 的那条)。 */
export interface PtyChannel {
  /** 写入(键盘/语音/控制字节)。内部派发后台单线程,调用方可在任意线程调。 */
  write(data: Uint8Array): void;
  /** 远端 PTY 尺寸变化(xterm fit 后 syncSize)。 */
  resize(cols: number, rows: number): void;
  /** 关闭通道(返回列表 / 切 project)。tmux session 在远端持久存活。 */
  close(): void;
}

/** 一条已建立 + 已认证的 SSH 连接(可能经 via 跳板 / proxy 隧道)。 */
export interface SshSession {
  /**
   * 开交互式 PTY shell(attach tmux)。返回可写的 PtyChannel;远端输出经 onData 流式回送。
   * startupCommand = `tmuxAttachCommand`(注入 conf + UTF-8 + attach),见 terminal 侧。
   */
  openShell(cols: number, rows: number, startupCommand: string,
            onData: PtyDataSink, onClose: () => void): Promise<PtyChannel>;

  /**
   * 短命 exec channel,跑一条非交互命令拿全部 stdout(cat manifest/status)。
   * 对齐 Android `HostClient.catFile` / 状态批量 capture。
   */
  exec(command: string): Promise<string>;

  /** 关闭整条 SSH 连接。 */
  close(): void;
}

/**
 * backend 工厂:把 HostConfig(已解析 via/proxy/key)拨成一条已认证 SshSession。
 * 实现:NativeSshBackend(路径 A,libssh2)/ ArkSshBackend(路径 B,纯 ArkTS)。
 */
export interface SshBackend {
  /**
   * @param host       目标 host 配置(端到端认证的目标)
   * @param viaSession 若 host 有 via:已连好的跳板 SshSession,backend 在其上开 direct-tcpip 到内网目标;
   *                   无 via 则 null,直接拨公网(可能经 proxy 隧道)。
   */
  connect(host: HostConfig, viaSession: SshSession | null): Promise<SshSession>;
  /** 该 backend 是否可用(路径 A:libsshbridge.so 是否 build 进包 → 反射/import 探测)。 */
  available(): boolean;
}
