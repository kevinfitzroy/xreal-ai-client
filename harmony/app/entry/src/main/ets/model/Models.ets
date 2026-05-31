/**
 * 数据模型 —— 对齐 Android `AgentModels.kt` + SPEC §2/§3/§8。
 * 形状是跨端契约,改这里前先看 SPEC。
 */

/** SSH-over-443 命名代理(SPEC §5.1 / §8 proxies[])。当前只支持 vmess://。 */
export interface ProxyConfig {
  name: string;     // 唯一名,host 用 proxy 字段按名引用
  url: string;      // vmess:// 分享链接
}

/** ASR 凭证(SPEC §7 / §8 asr)。经 Valet 导入,无设置 UI。 */
export interface AsrConfig {
  provider: string;     // "VOLC"
  appid: string;
  token: string;
  resourceId: string;   // 默认 volc.seedasr.sauc.duration
}

/** host 配置(SPEC §8 hosts[])。真实 IP 只进 host,绝不进 addr/UI。 */
export interface HostConfig {
  name: string;            // 唯一名,也用于私钥落地文件名
  addr?: string;           // 显示别名(可含用户名,不含真实 IP)
  host: string;            // 真实连接地址(IP/域名),UI 不显示
  port: number;            // 默认 22
  user: string;
  key: string;             // 私钥文件名(导入后 keys/<name>.pem)
  privateKeyPem?: string;  // 内联 PEM(导入时落盘;运行时从私有存储读)
  basePath?: string;       // manifest/status 在 <basePath>/.xreal/ 下;空=不 live-fetch
  via?: string;            // 多跳跳板 host 名(SPEC §5)
  proxy?: string;          // 经哪个 proxy 拨号(SPEC §5.1);无则直连
  projects?: ProjectInfo[];// seed(真相由 manifest 覆盖)
}

/** project 类型(SPEC §2 type 枚举)。决定分类 + 语音前缀(§4)。 */
export type ProjectType = 'maestro' | 'claude' | 'agent' | 'ssh';

export function isAiAgent(t: ProjectType): boolean { return t !== 'ssh'; }

/** project(SPEC §2 projects[])。 */
export interface ProjectInfo {
  session: string;        // tmux session 名;只允许 [A-Za-z0-9_.-]
  name: string;           // 显示名(可中文)
  type: ProjectType;
  dir?: string;
  group?: string;
  startup?: string;
  hotwords?: string[];    // project 级语音热词(§7)
}

/** 运行状态(SPEC §3)。hooks 事件驱动上报,客户端只读。 */
export type AgentState = 'working' | 'waiting' | 'needs-permission' | 'disconnected' | 'unknown';

export interface SessionStatus {
  session: string;
  state: AgentState;
  since: number;          // 进入当前 state 的 epoch 秒
  updated?: number;
}

/**
 * 推给 index.html `window.setHosts` 的渲染 JSON 形状(SPEC §3 + ROADMAP §4 JSON 契约)。
 * 形状:[{name,addr,up,proxy?,projects:[{name,session,type,state,since,preview}]}]
 * preview 当前恒 null(最近命令预览需抓屏,搁置 P2.2)。
 */
export interface RenderProject {
  name: string;
  session: string;
  type: ProjectType;
  state?: AgentState;     // hooks 实时态;无则不显示徽章
  since?: number;
  loading?: boolean;
  preview: null;          // 占位,见 ROADMAP P2.2
}

export interface RenderHost {
  name: string;
  addr: string;           // 显示别名(脱敏)
  up: boolean;
  proxy?: string;         // 生效 proxy 名(🔒 徽章;SPEC §5.1 归属规则)
  projects: RenderProject[];
}
