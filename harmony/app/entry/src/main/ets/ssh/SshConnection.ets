import { HostConfig } from '../model/Models';
import { SshSession, PtyChannel, PtyDataSink, SshBackend } from './PtyChannel';
import { makeBackend } from './SshBackend';
import { Log } from '../util/Logger';

/**
 * 连接门面 —— 对齐 Android `SshConnection` + `SshJump` 的编排部分。
 * 把「解析 via 跳板链 → (经 proxy 隧道)拨号 → 端到端认证 → 开 PTY/exec」串起来,
 * 底层传输委托给选定的 backend(native / arkts,见 SshBackend.ets)。
 *
 * 多跳(SPEC §5 via):host.via 指向跳板 host;先连跳板,再让 backend 在跳板上开 direct-tcpip 到内网目标。
 * proxy(SPEC §5.1):proxy 归属「拨公网那一跳」—— 直连 host 用自己的 proxy;经 via 的内网 host 由跳板的 proxy 决定。
 *   ⚠️ proxy 隧道(xray/sing-box 等价物)在 HarmonyOS 上是**另一个悬置决策**(见 DECISIONS.md D2),
 *      第一版 connect 仅把 proxy 解析后的本地端口透传给 backend;隧道内核接入待定。
 */
const TAG = 'SshConnection';

export class SshConnection {
  private backend: SshBackend = makeBackend();
  private session: SshSession | null = null;
  private channel: PtyChannel | null = null;

  /** 解析 host 的连接链(via 跳板递归),返回端到端可用的 SshSession。 */
  async connect(host: HostConfig, hostsByName: Map<string, HostConfig>): Promise<SshSession> {
    if (!this.backend.available()) {
      throw new Error(`SSH backend (${this.backend.constructor.name}) 不可用 —— ` +
        `路径 A 需 build libsshbridge.so;或在 SshBackend.ets 切到 'arkts'。见 docs/ssh-options.md`);
    }
    let viaSession: SshSession | null = null;
    if (host.via) {
      const jump = hostsByName.get(host.via);
      if (!jump) { throw new Error(`via 跳板未配置: ${host.via}`); }
      Log.i(TAG, `${host.name} via ${jump.name} → 先连跳板`);
      viaSession = await this.connect(jump, hostsByName);   // 递归支持多跳
    }
    Log.i(TAG, `connect ${host.name} (proxy=${host.proxy ?? '-'}, via=${host.via ?? '-'})`);
    this.session = await this.backend.connect(host, viaSession);
    return this.session;
  }

  /** 开交互式 PTY(attach tmux),热切到此通道。 */
  async openShell(cols: number, rows: number, startupCommand: string,
                  onData: PtyDataSink, onClose: () => void): Promise<PtyChannel> {
    if (!this.session) { throw new Error('connect() 未先调用'); }
    this.channel = await this.session.openShell(cols, rows, startupCommand, onData, onClose);
    return this.channel;
  }

  /** 短命 exec(cat manifest/status)。 */
  exec(command: string): Promise<string> {
    if (!this.session) { throw new Error('connect() 未先调用'); }
    return this.session.exec(command);
  }

  activeChannel(): PtyChannel | null { return this.channel; }

  close(): void {
    try { this.channel?.close(); } catch (e) {}
    try { this.session?.close(); } catch (e) {}
    this.channel = null; this.session = null;
  }
}

/**
 * tmux attach 启动命令 —— port 自 Android `MainActivity.tmuxAttachCommand`(SPEC §5 tmux 约定)。
 * 注入 conf(history-limit 50000 + 半页翻页 bindings)+ UTF-8 locale + `tmux -u`。服务端零增量。
 * session 名只信任 [A-Za-z0-9_.-](拼进 shell)。
 */
export function tmuxAttachCommand(session: string, confB64: string): string {
  const c = '/tmp/.xreal-tmux.conf';
  return 'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; ' +
    'export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"; ' +
    `echo ${confB64} | base64 -d > ${c}; ` +
    `tmux source-file ${c} 2>/dev/null; ` +
    `exec tmux -u -f ${c} new -A -s '${session}'`;
}

/** 注入的 tmux conf 文本(与 Android 一致)。调用方 Base64 后传给 tmuxAttachCommand。 */
export const TMUX_CONF =
  'source-file -q ~/.tmux.conf\n' +
  'set -g history-limit 50000\n' +
  'bind -n S-Up "copy-mode ; send-keys -X halfpage-up"\n' +
  'bind -n S-Down \'if -F "#{pane_in_mode}" "send-keys -X halfpage-down"\'\n';
