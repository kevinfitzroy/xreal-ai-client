import { SshBackend } from './PtyChannel';
import { NativeSshBackend } from './backend/NativeSshChannel';
import { ArkSshBackend } from './backend/ArkSshSession';

/**
 * ⭐ 悬置的人工决策点:SSH backend 选哪条路(见 docs/ssh-options.md + docs/DECISIONS.md D1)。
 *
 *   'native' = 路径 A:libssh2 + NAPI(.so)。贴合 Android sshj 哲学(成熟库 + 薄封装),
 *              有原生 direct_tcpip 做 ProxyJump。**需交叉编译 libssh2.so + 有编译环境**。
 *   'arkts'  = 路径 B:纯 ArkTS over TCPSocket + cryptoFramework。零 native、100% 可审计,
 *              但要手搓 SSH 协议栈(数千行),且 chacha20-poly1305 要 API 22+。骨架已起,未完成。
 *
 * 默认 'arkts':纯 ArkTS 不依赖 native 工具链,工程能直接打开/编译(协议未完成 → 连接会抛 NotImplemented)。
 * 用户明天拍板后改这一个常量即可切换;两条路都实现同一组 PtyChannel 接口,上层零改动。
 */
export type SshBackendKind = 'native' | 'arkts';
export const BACKEND: SshBackendKind = 'arkts';

export function makeBackend(): SshBackend {
  return BACKEND === 'native' ? new NativeSshBackend() : new ArkSshBackend();
}
